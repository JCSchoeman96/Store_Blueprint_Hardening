if Mix.env() != :test do
  raise "checkout_write_contention.exs must be run with MIX_ENV=test"
end

Code.require_file(Path.expand("../../test/support/stripe_api_stub.ex", __DIR__))

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
Store.Perf.BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "checkout_write_contention.exs expects standalone startup"
end

Store.Perf.BenchmarkHarness.configure_repos!()

Application.put_env(
  :store,
  StoreWeb.Endpoint,
  Application.get_env(:store, StoreWeb.Endpoint, [])
  |> Keyword.merge(server: false)
)

Application.put_env(:store, Oban,
  repo: Store.DirectRepo,
  testing: :manual,
  plugins: false,
  queues: false
)

{:ok, _} = Application.ensure_all_started(:store)

defmodule Store.Perf.CheckoutWriteContention do
  @moduledoc false

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Payments
  alias Store.Perf.CheckoutWriteReport
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  def run do
    started_at = System.monotonic_time()
    deadline = started_at + System.convert_time_unit(duration_ms(), :millisecond, :native)
    ready_path = System.get_env("STORE_CONTENTION_READY_PATH")

    data =
      System.get_env("STORE_BENCHMARK_DATA_PATH", "tmp/perf/benchmark_data.json")
      |> File.read!()
      |> Jason.decode!()

    {:ok, metrics_agent} = Agent.start_link(fn -> [] end)
    {:ok, fingerprint_agent} = Agent.start_link(fn -> MapSet.new() end)

    maybe_write_ready_file(ready_path)
    IO.puts("WRITER_READY")

    tasks =
      for index <- 0..(writer_users() - 1) do
        delay_ms = floor(index * 1000 / max(writer_ramp_per_second(), 1))

        Task.async(fn ->
          Process.sleep(delay_ms)
          setup_stripe_stub()
          writer_loop(data, index, deadline, 0, metrics_agent, fingerprint_agent)
        end)
      end

    task_results = Task.await_many(tasks, duration_ms() + 60_000)
    metrics = Agent.get(metrics_agent, &Enum.reverse/1)
    Agent.stop(metrics_agent)
    Agent.stop(fingerprint_agent)

    result = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: System.get_env("STORE_PHASE307_MODE", "quick"),
      users: writer_users(),
      ramp_per_second: writer_ramp_per_second(),
      duration_ms: duration_ms(),
      totals: summarize_task_results(task_results, metrics),
      steps: summarize_steps(metrics, sample_cap: sample_cap())
    }

    output_path =
      System.get_env(
        "STORE_CHECKOUT_WRITE_CONTENTION_PATH",
        "tmp/perf/checkout_write_contention.json"
      )

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode_to_iodata!(result, pretty: true))

    IO.puts("Wrote checkout contention results to #{output_path}")
    result
  end

  defp writer_loop(data, user_index, deadline, iteration, metrics_agent, fingerprint_agent) do
    if System.monotonic_time() >= deadline do
      :ok
    else
      record = execute_checkout_cycle(data, user_index, iteration)
      emit_new_failure_fingerprints(record, fingerprint_agent)
      Agent.update(metrics_agent, &[record | &1])
      writer_loop(data, user_index, deadline, iteration + 1, metrics_agent, fingerprint_agent)
    end
  end

  defp execute_checkout_cycle(data, user_index, iteration) do
    variant_id = pick_variant_id(data, user_index, iteration)
    cart_token = Ash.UUIDv7.generate()
    actor = %{cart_token: cart_token}
    base = %{user_index: user_index, iteration: iteration, variant_id: variant_id}

    try do
      with :ok <- run_add_item_step(cart_token, variant_id, base),
           {:ok, start_record, checkout_key} <- run_start_step(cart_token, base),
           {:ok, shipping_record} <- run_shipping_step(actor, checkout_key, data, base),
           {:ok, finalize_record} <- run_finalize_step(actor, checkout_key, base),
           {:ok, intent_record} <- run_intent_step(actor, checkout_key, base) do
        %{
          status: :ok,
          steps: [start_record, shipping_record, finalize_record, intent_record]
        }
      else
        {:error, record} ->
          %{status: :error, steps: [record]}
      end
    rescue
      error ->
        %{
          status: :error,
          steps: [
            exception_record(
              :start_from_cart,
              base,
              error,
              __STACKTRACE__
            )
          ]
        }
    catch
      kind, reason ->
        %{
          status: :error,
          steps: [
            throw_record(
              :start_from_cart,
              base,
              kind,
              reason
            )
          ]
        }
    end
  end

  defp add_item(cart_token, variant_id) do
    {:ok, input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    CartsFacade.add_item_for_user(nil, cart_token, input)
  end

  defp run_add_item_step(cart_token, variant_id, base) do
    {result, repo_stats, duration_native} =
      capture(fn -> add_item(cart_token, variant_id) end)

    case result do
      {:ok, _cart} ->
        :ok

      {:error, _error} ->
        {:error, record(:add_item, base, result, repo_stats, duration_native)}
    end
  end

  defp run_start_step(cart_token, base) do
    {:ok, input} = CheckoutStartInput.new(%{})

    {result, repo_stats, duration_native} =
      capture(fn -> Checkout.start_from_cart(nil, cart_token, input) end)

    case result do
      {:ok, start_result} ->
        {:ok, record(:start_from_cart, base, result, repo_stats, duration_native),
         start_result.checkout_key}

      {:error, _error} ->
        {:error, record(:start_from_cart, base, result, repo_stats, duration_native)}
    end
  end

  defp run_shipping_step(actor, checkout_key, data, base) do
    {:ok, input} = CheckoutShippingInput.new(data["checkout"]["shipping_form"])

    {result, repo_stats, duration_native} =
      capture(fn -> Checkout.set_shipping(actor, checkout_key, input) end)

    case result do
      {:ok, _checkout} ->
        {:ok, record(:set_shipping, base, result, repo_stats, duration_native)}

      {:error, _error} ->
        {:error, record(:set_shipping, base, result, repo_stats, duration_native)}
    end
  end

  defp run_finalize_step(actor, checkout_key, base) do
    {:ok, input} = CheckoutFinalizeInput.new(%{})

    {result, repo_stats, duration_native} =
      capture(fn -> Checkout.finalize_totals(actor, checkout_key, input) end)

    case result do
      {:ok, _checkout} ->
        {:ok, record(:finalize_totals, base, result, repo_stats, duration_native)}

      {:error, _error} ->
        {:error, record(:finalize_totals, base, result, repo_stats, duration_native)}
    end
  end

  defp run_intent_step(actor, checkout_key, base) do
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    {result, repo_stats, duration_native} =
      capture(fn -> Payments.create_intent_for_order(actor, checkout_key, input) end)

    case result do
      {:ok, _intent} ->
        {:ok, record(:create_payment_intent, base, result, repo_stats, duration_native)}

      {:error, _error} ->
        {:error, record(:create_payment_intent, base, result, repo_stats, duration_native)}
    end
  end

  defp capture(fun) do
    started = System.monotonic_time()
    {result, repo_stats} = RepoStats.capture(fun)
    {result, repo_stats, System.monotonic_time() - started}
  end

  defp record(step, base, result, repo_stats, duration_native) do
    error_meta = error_meta(result)

    Map.merge(base, %{
      step: step,
      status: step_status(result),
      error_code: Map.get(error_meta, :error_code),
      exception_module: Map.get(error_meta, :exception_module),
      message: Map.get(error_meta, :message),
      error_detail: Map.get(error_meta, :error_detail),
      checkout_stage: Map.get(error_meta, :checkout_stage),
      duration_ms: native_to_ms(duration_native),
      query_count: Map.get(repo_stats, :query_count, 0),
      queue_time_ms: native_to_ms(Map.get(repo_stats, :queue_time, 0)),
      query_time_ms: native_to_ms(Map.get(repo_stats, :query_time, 0)),
      decode_time_ms: native_to_ms(Map.get(repo_stats, :decode_time, 0))
    })
    |> put_failure_fingerprint()
  end

  defp summarize_task_results(task_results, metrics) do
    cycles = Enum.count(metrics)
    successful_cycles = Enum.count(metrics, &(&1.status == :ok))

    %{
      completed_tasks: length(task_results),
      completed_cycles: cycles,
      successful_cycles: successful_cycles,
      failed_cycles: cycles - successful_cycles
    }
  end

  defp summarize_steps(metrics, opts) do
    metrics
    |> Enum.flat_map(&Map.get(&1, :steps, []))
    |> Enum.group_by(& &1.step)
    |> Enum.into(%{}, fn {step, rows} ->
      {to_string(step), CheckoutWriteReport.summarize_step_rows(rows, opts)}
    end)
  end

  defp pick_variant_id(data, user_index, iteration) do
    variants = get_in(data, ["checkout", "distributed_variant_ids"])
    Enum.at(variants, rem(user_index + iteration, length(variants)))
  end

  defp maybe_write_ready_file(nil), do: :ok
  defp maybe_write_ready_file(""), do: :ok
  defp maybe_write_ready_file(path), do: File.write!(path, "ready\n")

  defp setup_stripe_stub do
    :ok = Req.Test.set_req_test_to_private(%{})
    StripeAPIStub.stub_default()
  end

  defp step_status({:ok, _}), do: :ok
  defp step_status(_), do: :error

  defp exception_record(step, base, error, stacktrace) do
    Map.merge(base, %{
      step: step,
      status: :error,
      error_code: exception_code(error),
      exception_module: inspect(error.__struct__),
      message: Exception.message(error),
      error_detail: Exception.format(:error, error, stacktrace),
      checkout_stage: nil,
      duration_ms: 0.0,
      query_count: 0,
      queue_time_ms: 0.0,
      query_time_ms: 0.0,
      decode_time_ms: 0.0
    })
    |> put_failure_fingerprint()
  end

  defp throw_record(step, base, kind, reason) do
    Map.merge(base, %{
      step: step,
      status: :error,
      error_code: "UNCAUGHT_#{kind |> Atom.to_string() |> String.upcase()}",
      exception_module: nil,
      message: inspect(reason),
      error_detail: Exception.format(kind, reason, []),
      checkout_stage: nil,
      duration_ms: 0.0,
      query_count: 0,
      queue_time_ms: 0.0,
      query_time_ms: 0.0,
      decode_time_ms: 0.0
    })
    |> put_failure_fingerprint()
  end

  defp exception_code(%Ecto.ConstraintError{}), do: "UNHANDLED_CONSTRAINT_ERROR"
  defp exception_code(_error), do: "UNHANDLED_EXCEPTION"

  defp error_meta({:error, error}) do
    normalized = Normalize.normalize(error)

    %{
      error_code: Map.get(normalized, :code, "INTERNAL_ERROR"),
      exception_module: exception_module(error),
      message: Map.get(normalized, :message),
      error_detail: format_error_detail(error),
      checkout_stage: error_checkout_stage(normalized)
    }
  end

  defp error_meta(_result), do: %{}

  defp exception_module(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp exception_module(_error), do: nil

  defp format_error_detail(error) do
    error
    |> Exception.message()
    |> CheckoutWriteReport.truncate_detail()
  rescue
    _ -> CheckoutWriteReport.truncate_detail(error)
  end

  defp error_checkout_stage(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :checkout_stage) || Map.get(meta, "checkout_stage")
  end

  defp error_checkout_stage(_error), do: nil

  defp put_failure_fingerprint(%{status: :error} = row) do
    Map.put(row, :failure_fingerprint, CheckoutWriteReport.failure_fingerprint(row))
  end

  defp put_failure_fingerprint(row), do: row

  defp emit_new_failure_fingerprints(record, fingerprint_agent) do
    record
    |> Map.get(:steps, [])
    |> Enum.filter(fn
      %{status: :error} -> true
      _ -> false
    end)
    |> Enum.each(fn step ->
      fingerprint = Map.get(step, :failure_fingerprint)

      if is_binary(fingerprint) do
        is_new? =
          Agent.get_and_update(fingerprint_agent, fn fingerprints ->
            if MapSet.member?(fingerprints, fingerprint) do
              {false, fingerprints}
            else
              {true, MapSet.put(fingerprints, fingerprint)}
            end
          end)

        if is_new? do
          IO.puts(
            "WRITER_FAILURE_FINGERPRINT " <>
              "#{fingerprint} step=#{step.step} code=#{step.error_code} " <>
              "stage=#{step.checkout_stage || "unknown"} " <>
              "exception=#{step.exception_module || "n/a"} " <>
              "message=#{step.message || "unknown"}"
          )
        end
      end
    end)
  end

  defp native_to_ms(value) when is_integer(value) do
    value / System.convert_time_unit(1, :millisecond, :native)
  end

  defp sample_cap do
    System.get_env("STORE_CHECKOUT_WRITE_CONTENTION_SAMPLE_CAP", "20")
    |> String.to_integer()
  end

  defp writer_users do
    System.get_env("STORE_CONTENTION_WRITER_USERS", "20")
    |> String.to_integer()
  end

  defp writer_ramp_per_second do
    System.get_env("STORE_CONTENTION_WRITER_RAMP_PER_SECOND", "5")
    |> String.to_integer()
  end

  defp duration_ms do
    System.get_env("STORE_CONTENTION_DURATION_MS", "90000")
    |> String.to_integer()
  end
end

Store.Perf.CheckoutWriteContention.run()
