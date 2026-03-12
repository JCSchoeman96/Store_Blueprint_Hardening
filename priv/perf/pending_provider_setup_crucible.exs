if Mix.env() != :test do
  raise "pending_provider_setup_crucible.exs must be run with MIX_ENV=test"
end

Code.require_file(Path.expand("../../test/support/stripe_api_stub.ex", __DIR__))

Code.ensure_loaded!(Store.Perf.BenchmarkHarness)
Store.Perf.BenchmarkHarness.require_isolated_test_db!()

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise "pending_provider_setup_crucible.exs expects standalone startup"
end

repo_config = Application.get_env(:store, Store.Repo, [])
direct_repo_config = Application.get_env(:store, Store.DirectRepo, [])

Application.put_env(
  :store,
  Store.Repo,
  Keyword.merge(repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size:
      System.get_env(
        "STORE_BENCH_WRITER_POOL_SIZE",
        repo_config |> Keyword.get(:pool_size, 20) |> to_string()
      )
      |> String.to_integer(),
    prepare: :unnamed,
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

Application.put_env(
  :store,
  Store.DirectRepo,
  Keyword.merge(direct_repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size:
      System.get_env(
        "STORE_BENCH_WRITER_DIRECT_POOL_SIZE",
        direct_repo_config |> Keyword.get(:pool_size, 10) |> to_string()
      )
      |> String.to_integer(),
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

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

defmodule Store.Perf.PendingProviderSetupCrucible do
  @moduledoc false

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders.Order
  alias Store.Payments
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Repo
  alias Store.Support.Errors.Normalize
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ExpirePendingProviderSetupOrdersWorker

  @pending_state_poll_interval_ms 100
  @pending_state_timeout_ms 5_000
  @sample_interval_ms 5_000
  @backlog_zero_timeout_ms 90_000
  @probe_expected_codes MapSet.new(["OUT_OF_STOCK", "RESERVATION_CONFLICT"])

  def run do
    config = crucible_config()
    ready_path = System.get_env("STORE_PENDING_PROVIDER_SETUP_CRUCIBLE_READY_PATH")

    output_path =
      System.get_env(
        "STORE_PENDING_PROVIDER_SETUP_CRUCIBLE_PATH",
        "tmp/perf/pending_provider_setup_crucible_writer.json"
      )

    data = load_benchmark_data()

    {:ok, backlog_agent} = Agent.start_link(fn -> [] end)
    {:ok, sweep_agent} = Agent.start_link(fn -> [] end)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    sweeper_loop = start_sweeper_loop(config, sweep_agent)
    backlog_loop = start_backlog_loop(backlog_agent)

    maybe_write_ready_file(ready_path)
    IO.puts("CRUCIBLE_READY")

    try do
      abandoned_wave =
        StripeAPIStub.with_chaos_override(
          %{mode: :slow, delay_ms: config.provider_delay_ms},
          fn ->
            run_abandoned_wave(data, config, task_supervisor)
          end
        )

      probe_wave = run_probe_wave(data, config)

      backlog_zero =
        wait_for_backlog_zero(config)

      second_wave = run_second_wave(data, config)

      final_backlog =
        Store.Orders.pending_provider_setup_backlog_snapshot(DateTime.utc_now(),
          emit_telemetry?: false
        )

      result =
        %{
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          config: %{
            ttl_seconds: config.ttl_seconds,
            sweep_batch_size: config.sweep_batch_size,
            sweep_interval_ms: config.sweep_interval_ms,
            provider_delay_ms: config.provider_delay_ms,
            abandon_enabled?: config.abandon_enabled?,
            abandon_after_step: config.abandon_after_step,
            abandoned_clients: config.abandoned_clients,
            probe_clients: config.probe_clients,
            second_wave_clients: config.second_wave_clients
          },
          waves: %{
            abandoned: summarize_wave(abandoned_wave),
            probe: summarize_wave(probe_wave),
            second_wave: summarize_wave(second_wave)
          },
          backlog_samples: Agent.get(backlog_agent, &Enum.reverse/1),
          sweep_batches: Agent.get(sweep_agent, &Enum.reverse/1),
          backlog_zero: backlog_zero,
          final_backlog: final_backlog
        }
        |> add_assertions(config)

      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, Jason.encode_to_iodata!(result, pretty: true))
      IO.puts("Wrote pending provider setup crucible results to #{output_path}")
      result
    after
      stop_loop(backlog_loop)
      stop_loop(sweeper_loop)
      Agent.stop(backlog_agent)
      Agent.stop(sweep_agent)
      Process.exit(task_supervisor, :normal)
    end
  end

  defp run_abandoned_wave(data, config, task_supervisor) do
    run_wave(0..(config.abandoned_clients - 1), fn user_index ->
      variant_id = select_variant_id(data, user_index)

      with {:ok, prepared} <- prepare_checkout(data, variant_id),
           {:ok, abandoned} <- abandon_pending_provider_setup(prepared, task_supervisor, config) do
        Map.put(abandoned, :variant_id, variant_id)
      end
    end)
  end

  defp run_probe_wave(data, config) do
    run_wave(0..(config.probe_clients - 1), fn user_index ->
      variant_id = select_variant_id(data, user_index)

      case prepare_checkout(data, variant_id) do
        {:ok, prepared} ->
          %{
            status: :unexpected_success,
            variant_id: variant_id,
            order_id: prepared.order_id,
            checkout_key: prepared.checkout_key,
            step: "finalize_totals"
          }

        {:error, error} ->
          Map.merge(error, %{variant_id: variant_id})
      end
    end)
  end

  defp run_second_wave(data, config) do
    run_wave(0..(config.second_wave_clients - 1), fn user_index ->
      variant_id = select_variant_id(data, user_index)

      with {:ok, prepared} <- prepare_checkout(data, variant_id),
           {:ok, intent_result} <- create_intent(prepared.actor, prepared.checkout_key) do
        %{
          status: :ok,
          variant_id: variant_id,
          order_id: prepared.order_id,
          checkout_key: prepared.checkout_key,
          payment_intent_id: intent_result.payment_intent_id
        }
      else
        {:error, error} ->
          Map.merge(error, %{variant_id: variant_id})
      end
    end)
  end

  defp prepare_checkout(data, variant_id) do
    cart_token = Ash.UUIDv7.generate()
    actor = %{cart_token: cart_token}

    with :ok <- setup_stripe_stub(),
         {:ok, _cart} <- add_item_step(cart_token, variant_id),
         {:ok, start_result} <- start_checkout_step(cart_token),
         {:ok, _checkout} <- set_shipping_step(actor, start_result.checkout_key, data),
         {:ok, _checkout} <- finalize_checkout_step(actor, start_result.checkout_key),
         {:ok, payment_context} <-
           Checkout.get_payment_context_for_user(actor, start_result.checkout_key) do
      {:ok,
       %{
         actor: actor,
         cart_token: cart_token,
         checkout_key: start_result.checkout_key,
         order_id: payment_context.order_id
       }}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp abandon_pending_provider_setup(prepared, task_supervisor, config) do
    unless config.abandon_enabled? and config.abandon_after_step == "create_payment_intent" do
      raise "pending provider setup crucible only supports abandonment after create_payment_intent"
    end

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        setup_stripe_stub()
        create_intent(prepared.actor, prepared.checkout_key)
      end)

    case wait_for_pending_provider_setup(prepared.order_id) do
      :ok ->
        Task.shutdown(task, :brutal_kill)

        {:ok,
         %{
           status: :abandoned,
           order_id: prepared.order_id,
           checkout_key: prepared.checkout_key,
           abandon_after_step: "create_payment_intent",
           provider_delay_ms: config.provider_delay_ms
         }}

      {:error, reason} ->
        Task.shutdown(task, :brutal_kill)

        {:error,
         error_map("PENDING_PROVIDER_SETUP_TIMEOUT", inspect(reason), "create_payment_intent")}
    end
  end

  defp wait_for_pending_provider_setup(order_id) do
    deadline = System.monotonic_time(:millisecond) + @pending_state_timeout_ms

    wait_until(deadline, fn ->
      case Repo.get(Order, order_id) do
        %Order{state: :pending_provider_setup} -> :ok
        %Order{} -> :retry
        nil -> :retry
      end
    end)
  end

  defp wait_for_backlog_zero(config) do
    deadline =
      System.monotonic_time(:millisecond) +
        config.ttl_seconds * 1_000 +
        @backlog_zero_timeout_ms

    started_waiting_at = DateTime.utc_now() |> DateTime.to_iso8601()

    result =
      wait_until(deadline, fn ->
        snapshot =
          Store.Orders.pending_provider_setup_backlog_snapshot(DateTime.utc_now(),
            emit_telemetry?: false
          )

        if snapshot.count == 0, do: {:ok, snapshot}, else: :retry
      end)

    case result do
      {:ok, snapshot} ->
        %{
          status: :ok,
          started_waiting_at: started_waiting_at,
          cleared_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          snapshot: snapshot
        }

      {:error, :timeout} ->
        %{
          status: :timeout,
          started_waiting_at: started_waiting_at,
          cleared_at: nil,
          snapshot:
            Store.Orders.pending_provider_setup_backlog_snapshot(DateTime.utc_now(),
              emit_telemetry?: false
            )
        }
    end
  end

  defp run_wave(enumerable, fun) do
    max_concurrency =
      enumerable
      |> Enum.count()
      |> max(1)

    enumerable
    |> Task.async_stream(
      fun,
      ordered: false,
      timeout: 180_000,
      max_concurrency: max_concurrency
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> error_map("TASK_EXIT", inspect(reason), "wave")
    end)
  end

  defp add_item(cart_token, variant_id) do
    {:ok, input} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    CartsFacade.add_item_for_user(nil, cart_token, input)
  end

  defp add_item_step(cart_token, variant_id) do
    case add_item(cart_token, variant_id) do
      {:ok, cart} -> {:ok, cart}
      {:error, error} -> {:error, error_details(error, "add_item")}
    end
  end

  defp start_checkout(cart_token) do
    {:ok, input} = CheckoutStartInput.new(%{})
    Checkout.start_from_cart(nil, cart_token, input)
  end

  defp start_checkout_step(cart_token) do
    case start_checkout(cart_token) do
      {:ok, start_result} -> {:ok, start_result}
      {:error, error} -> {:error, error_details(error, "start_from_cart")}
    end
  end

  defp set_shipping(actor, checkout_key, data) do
    {:ok, input} = CheckoutShippingInput.new(data["checkout"]["shipping_form"])
    Checkout.set_shipping(actor, checkout_key, input)
  end

  defp set_shipping_step(actor, checkout_key, data) do
    case set_shipping(actor, checkout_key, data) do
      {:ok, checkout} -> {:ok, checkout}
      {:error, error} -> {:error, error_details(error, "set_shipping")}
    end
  end

  defp finalize_checkout(actor, checkout_key) do
    {:ok, input} = CheckoutFinalizeInput.new(%{})
    Checkout.finalize_totals(actor, checkout_key, input)
  end

  defp finalize_checkout_step(actor, checkout_key) do
    case finalize_checkout(actor, checkout_key) do
      {:ok, checkout} -> {:ok, checkout}
      {:error, error} -> {:error, error_details(error, "finalize_totals")}
    end
  end

  defp create_intent(actor, checkout_key) do
    {:ok, input} = CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    case Payments.create_intent_for_order(actor, checkout_key, input) do
      {:ok, intent_result} -> {:ok, intent_result}
      {:error, error} -> {:error, error_details(error, "create_payment_intent")}
    end
  end

  defp summarize_wave(results) do
    status_counts = Enum.frequencies_by(results, &Map.get(&1, :status, :unknown))

    error_code_counts =
      results
      |> Enum.map(&Map.get(&1, :error_code))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    %{
      client_count: length(results),
      status_counts: status_counts,
      success_count: Map.get(status_counts, :ok, 0),
      abandoned_count: Map.get(status_counts, :abandoned, 0),
      blocked_count: Map.get(status_counts, :blocked, 0),
      unexpected_success_count: Map.get(status_counts, :unexpected_success, 0),
      failed_count:
        Enum.reduce(status_counts, 0, fn
          {:ok, count}, acc -> acc
          {:abandoned, count}, acc -> acc
          {:blocked, count}, acc -> acc
          {_status, count}, acc -> acc + count
        end),
      error_code_counts: error_code_counts,
      sample_results: Enum.take(results, 10)
    }
  end

  defp add_assertions(result, config) do
    peak_backlog = peak_backlog(result.backlog_samples)
    expected_iterations = ceil_div(peak_backlog, config.sweep_batch_size)
    nonzero_batches = Enum.filter(result.sweep_batches, &(&1.swept_count > 0))
    actual_iterations = length(nonzero_batches)
    max_sweep_duration_ms = Enum.max([0.0 | Enum.map(nonzero_batches, & &1.duration_ms)])

    probe_codes =
      result.waves.probe.error_code_counts
      |> Map.keys()
      |> MapSet.new()

    zero_before_expiry? = result.waves.probe.unexpected_success_count == 0
    probe_conflict_only? = MapSet.subset?(probe_codes, @probe_expected_codes)
    second_wave_success? = result.waves.second_wave.success_count == config.second_wave_clients
    backlog_zero? = result.backlog_zero.status == :ok and result.final_backlog.count == 0
    batches_within_target? = max_sweep_duration_ms <= 500.0

    Map.put(result, :assertions, %{
      peak_backlog_observed?: peak_backlog > 0,
      probe_wave_zero_success_before_expiry?: zero_before_expiry?,
      probe_wave_expected_conflicts_only?: probe_conflict_only?,
      backlog_zero_within_window?: backlog_zero?,
      released_count_matches_swept_count?:
        total_released(result.sweep_batches) == total_swept(result.sweep_batches),
      second_wave_failed_cycles_zero?: second_wave_success?,
      expected_batch_iterations: expected_iterations,
      actual_batch_iterations: actual_iterations,
      batch_drain_matches_expectation?: actual_iterations == expected_iterations,
      max_sweep_duration_ms: max_sweep_duration_ms,
      batches_within_target?: batches_within_target?,
      same_seats_sellable_again?: zero_before_expiry? and backlog_zero? and second_wave_success?
    })
  end

  defp start_backlog_loop(agent) do
    spawn_link(fn -> backlog_loop(agent) end)
  end

  defp backlog_loop(agent) do
    captured_at = DateTime.utc_now()

    sample =
      Store.Orders.pending_provider_setup_backlog_snapshot(captured_at,
        source: :crucible_writer
      )
      |> Map.put(:captured_at, DateTime.to_iso8601(captured_at))

    Agent.update(agent, &[sample | &1])

    receive do
      :stop -> :ok
    after
      @sample_interval_ms -> backlog_loop(agent)
    end
  end

  defp start_sweeper_loop(config, agent) do
    spawn_link(fn -> sweeper_loop(config, agent) end)
  end

  defp sweeper_loop(config, agent) do
    now = DateTime.utc_now()
    started = System.monotonic_time()

    result =
      ExpirePendingProviderSetupOrdersWorker.sweep(now,
        ttl_seconds: config.ttl_seconds,
        batch_size: config.sweep_batch_size,
        source: :crucible_writer
      )

    event =
      case result do
        {:ok, sweep_result} ->
          %{
            captured_at: DateTime.to_iso8601(now),
            batch_size: config.sweep_batch_size,
            duration_ms: native_to_ms(System.monotonic_time() - started),
            swept_count: sweep_result.swept_count,
            released_count: sweep_result.released_count,
            order_ids: sweep_result.order_ids
          }

        {:error, reason} ->
          %{
            captured_at: DateTime.to_iso8601(now),
            batch_size: config.sweep_batch_size,
            duration_ms: native_to_ms(System.monotonic_time() - started),
            swept_count: 0,
            released_count: 0,
            order_ids: [],
            error: inspect(reason)
          }
      end

    Agent.update(agent, &[event | &1])

    receive do
      :stop -> :ok
    after
      config.sweep_interval_ms -> sweeper_loop(config, agent)
    end
  end

  defp stop_loop(nil), do: :ok

  defp stop_loop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp maybe_write_ready_file(nil), do: :ok
  defp maybe_write_ready_file(""), do: :ok
  defp maybe_write_ready_file(path), do: File.write!(path, "ready\n")

  defp setup_stripe_stub do
    :ok = Req.Test.set_req_test_to_private(%{})
    StripeAPIStub.stub_default()
    :ok
  end

  defp load_benchmark_data do
    System.get_env("STORE_BENCHMARK_DATA_PATH", "tmp/perf/benchmark_data.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp select_variant_id(data, user_index) do
    variant_ids = get_in(data, ["checkout", "crucible_variant_ids"]) || []

    case variant_ids do
      [] ->
        raise "benchmark_data.json is missing checkout.crucible_variant_ids for the pending provider setup crucible"

      _ ->
        Enum.at(variant_ids, rem(user_index, length(variant_ids)))
    end
  end

  defp error_details(error, step \\ nil) do
    normalized = Normalize.normalize(error)
    meta = Map.get(normalized, :meta, %{})

    %{
      status: :blocked,
      step:
        step || Map.get(meta, :checkout_stage) || Map.get(meta, "checkout_stage") || "unknown",
      error_code: Map.get(normalized, :code, "INTERNAL_ERROR"),
      message: Map.get(normalized, :message),
      error_detail: inspect(error)
    }
  end

  defp error_map(code, message, step) do
    %{
      status: :error,
      step: step,
      error_code: code,
      message: message,
      error_detail: message
    }
  end

  defp wait_until(deadline, fun) do
    case fun.() do
      :ok ->
        :ok

      {:ok, value} ->
        {:ok, value}

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@pending_state_poll_interval_ms)
          wait_until(deadline, fun)
        end
    end
  end

  defp peak_backlog(samples) do
    samples
    |> Enum.map(&Map.get(&1, :count, 0))
    |> Enum.max(fn -> 0 end)
  end

  defp total_released(sweep_batches) do
    Enum.sum(Enum.map(sweep_batches, &Map.get(&1, :released_count, 0)))
  end

  defp total_swept(sweep_batches) do
    Enum.sum(Enum.map(sweep_batches, &Map.get(&1, :swept_count, 0)))
  end

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  defp native_to_ms(value) when is_number(value) do
    value / System.convert_time_unit(1, :millisecond, :native)
  end

  defp crucible_config do
    %{
      ttl_seconds: env_integer("STORE_PROVIDER_SETUP_TTL_SECONDS", 30),
      sweep_batch_size: env_integer("STORE_PROVIDER_SETUP_SWEEP_BATCH_SIZE", 50),
      sweep_interval_ms: env_integer("STORE_PERF_PENDING_PROVIDER_SWEEP_INTERVAL_MS", 5_000),
      provider_delay_ms: env_integer("STORE_PERF_PENDING_PROVIDER_PROVIDER_DELAY_MS", 45_000),
      abandon_enabled?: env_boolean("STORE_PERF_PENDING_PROVIDER_ABANDON", true),
      abandon_after_step:
        System.get_env(
          "STORE_PERF_PENDING_PROVIDER_ABANDON_AFTER_STEP",
          "create_payment_intent"
        ),
      abandoned_clients: env_integer("STORE_PERF_PENDING_PROVIDER_CLIENTS", 200),
      probe_clients: env_integer("STORE_PERF_PENDING_PROVIDER_PROBE_CLIENTS", 5),
      second_wave_clients:
        env_integer(
          "STORE_PERF_PENDING_PROVIDER_SECOND_WAVE_CLIENTS",
          env_integer("STORE_PERF_PENDING_PROVIDER_CLIENTS", 200)
        )
    }
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end

  defp env_boolean(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        value
        |> String.downcase()
        |> case do
          "1" -> true
          "true" -> true
          "yes" -> true
          "on" -> true
          "0" -> false
          "false" -> false
          "no" -> false
          "off" -> false
          _ -> default
        end
    end
  end
end

Store.Perf.PendingProviderSetupCrucible.run()
