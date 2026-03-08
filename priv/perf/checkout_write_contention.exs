if Mix.env() != :test do
  raise "checkout_write_contention.exs must be run with MIX_ENV=test"
end

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
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats

  def run do
    started_at = System.monotonic_time()
    deadline = started_at + System.convert_time_unit(duration_ms(), :millisecond, :native)
    ready_path = System.get_env("STORE_CONTENTION_READY_PATH")

    data =
      System.get_env("STORE_BENCHMARK_DATA_PATH", "tmp/perf/benchmark_data.json")
      |> File.read!()
      |> Jason.decode!()

    {:ok, metrics_agent} = Agent.start_link(fn -> [] end)

    maybe_write_ready_file(ready_path)
    IO.puts("WRITER_READY")

    tasks =
      for index <- 0..(writer_users() - 1) do
        delay_ms = floor(index * 1000 / max(writer_ramp_per_second(), 1))

        Task.async(fn ->
          Process.sleep(delay_ms)
          writer_loop(data, index, deadline, 0, metrics_agent)
        end)
      end

    task_results = Task.await_many(tasks, duration_ms() + 60_000)
    metrics = Agent.get(metrics_agent, &Enum.reverse/1)
    Agent.stop(metrics_agent)

    result = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: System.get_env("STORE_PHASE307_MODE", "quick"),
      users: writer_users(),
      ramp_per_second: writer_ramp_per_second(),
      duration_ms: duration_ms(),
      totals: summarize_task_results(task_results, metrics),
      steps: summarize_steps(metrics)
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

  defp writer_loop(data, user_index, deadline, iteration, metrics_agent) do
    if System.monotonic_time() >= deadline do
      :ok
    else
      record = execute_checkout_cycle(data, user_index, iteration)
      Agent.update(metrics_agent, &[record | &1])
      writer_loop(data, user_index, deadline, iteration + 1, metrics_agent)
    end
  end

  defp execute_checkout_cycle(data, user_index, iteration) do
    variant_id = pick_variant_id(data, user_index, iteration)
    cart_token = Ash.UUIDv7.generate()
    actor = %{cart_token: cart_token}
    base = %{user_index: user_index, iteration: iteration, variant_id: variant_id}

    with {:ok, _cart} <- add_item(cart_token, variant_id),
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
  end

  defp add_item(cart_token, variant_id) do
    {:ok, input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    CartsFacade.add_item_for_user(nil, cart_token, input)
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
    Map.merge(base, %{
      step: step,
      status: step_status(result),
      error_code: error_code(result),
      duration_ms: native_to_ms(duration_native),
      query_count: Map.get(repo_stats, :query_count, 0),
      queue_time_ms: native_to_ms(Map.get(repo_stats, :queue_time, 0)),
      query_time_ms: native_to_ms(Map.get(repo_stats, :query_time, 0)),
      decode_time_ms: native_to_ms(Map.get(repo_stats, :decode_time, 0))
    })
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

  defp summarize_steps(metrics) do
    metrics
    |> Enum.flat_map(&Map.get(&1, :steps, []))
    |> Enum.group_by(& &1.step)
    |> Enum.into(%{}, fn {step, rows} ->
      {to_string(step),
       %{
         count: length(rows),
         success_count: Enum.count(rows, &(&1.status == :ok)),
         error_count: Enum.count(rows, &(&1.status == :error)),
         mean_duration_ms: average(rows, :duration_ms),
         p95_duration_ms: percentile(rows, :duration_ms, 0.95),
         mean_query_count: average(rows, :query_count),
         p95_query_count: percentile(rows, :query_count, 0.95),
         mean_queue_time_ms: average(rows, :queue_time_ms),
         mean_query_time_ms: average(rows, :query_time_ms),
         error_codes:
           rows |> Enum.map(& &1.error_code) |> Enum.reject(&is_nil/1) |> Enum.frequencies()
       }}
    end)
  end

  defp pick_variant_id(data, user_index, iteration) do
    variants = get_in(data, ["checkout", "distributed_variant_ids"])
    Enum.at(variants, rem(user_index + iteration, length(variants)))
  end

  defp maybe_write_ready_file(nil), do: :ok
  defp maybe_write_ready_file(""), do: :ok
  defp maybe_write_ready_file(path), do: File.write!(path, "ready\n")

  defp step_status({:ok, _}), do: :ok
  defp step_status(_), do: :error

  defp error_code({:error, error}) do
    error
    |> Normalize.normalize()
    |> Map.get(:code, "INTERNAL_ERROR")
  end

  defp error_code(_), do: nil

  defp average(rows, key) do
    values = Enum.map(rows, &Map.get(&1, key, 0))
    Enum.sum(values) / max(length(values), 1)
  end

  defp percentile(rows, key, ratio) do
    values = rows |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sort()

    case values do
      [] -> 0
      _ -> Enum.at(values, min(length(values) - 1, floor(length(values) * ratio)))
    end
  end

  defp native_to_ms(value) when is_integer(value) do
    value / System.convert_time_unit(1, :millisecond, :native)
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
