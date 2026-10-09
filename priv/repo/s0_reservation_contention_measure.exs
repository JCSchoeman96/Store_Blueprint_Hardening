if Mix.env() != :test do
  raise "s0_reservation_contention_measure.exs must run with MIX_ENV=test"
end

unless Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :store end) do
  :ok
else
  raise "run with mix run --no-start"
end

defmodule Store.S0ReservationContention.Measurement do
  @moduledoc false

  alias Store.Catalog.{InventoryItem, Product}
  alias Store.Orders
  alias Store.Orders.Order
  alias Store.Repo
  alias Store.TestFixtures

  @attempts_per_profile 5
  @caller_count 80
  @repo_pool_size 40
  @direct_repo_pool_size 10
  @sample_interval_ms 50
  @drain_observation_cap_ms 5_000
  @latency_mean_target_ms 250.0
  @pool_utilization_max_ratio 0.95
  @governed_loser_codes ["OUT_OF_STOCK", "RESERVATION_CONFLICT"]
  @report_root "/tmp/issue68-phase-b-measurements"

  @repo_application_name "store_perf_repo"
  @direct_application_name "store_perf_direct_repo"
  @sampler_application_name "s0_reservation_measurement"

  @sample_query """
  SELECT
    to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    COUNT(*) FILTER (WHERE state = 'active')::bigint AS active_backends,
    COUNT(*) FILTER (
      WHERE state = 'active' AND wait_event_type = 'Lock'
    )::bigint AS lock_waiters,
    COUNT(*) FILTER (
      WHERE state = 'active' AND application_name = $1
    )::bigint AS repo_active_backends,
    COUNT(*) FILTER (
      WHERE state = 'active'
        AND wait_event_type = 'Lock'
        AND application_name = $1
    )::bigint AS repo_lock_waiters,
    COALESCE(
      (
        SELECT deadlocks
        FROM pg_stat_database
        WHERE datname = current_database()
      ),
      0
    )::bigint AS database_deadlocks
  FROM pg_stat_activity
  WHERE datname = current_database()
    AND backend_type = 'client backend'
    AND pid <> $2
  """

  @inventory_snapshot_query """
  SELECT row_to_json(item)::text
  FROM inventory_items AS item
  WHERE item.variant_id = $1::uuid
  """

  @reservation_snapshot_query """
  SELECT row_to_json(reservation)::text
  FROM inventory_reservations AS reservation
  WHERE reservation.variant_id = $1::uuid
  ORDER BY reservation.order_id
  """

  def run! do
    profile = System.fetch_env!("S0_CONTENTION_PROFILE")

    unless profile in ["baseline", "mobile_realistic"] do
      raise "S0_CONTENTION_PROFILE must be baseline or mobile_realistic"
    end

    File.mkdir_p!(@report_root)
    refuse_existing_batch!(profile)
    configure_repositories!()
    {:ok, _started_apps} = Application.ensure_all_started(:store)
    verify_database_version!()
    _ = Ecto.Migrator.run(Store.Repo, Path.expand("migrations", __DIR__), :up, all: true)

    IO.puts(
      "S0 measurement profile=#{profile} attempts=#{@attempts_per_profile} callers=#{@caller_count} database=#{System.get_env("PGDATABASE", "store_test")} postgres=16.15"
    )

    reports =
      Enum.reduce_while(1..@attempts_per_profile, [], fn attempt, acc ->
        report = run_attempt(profile, attempt)
        write_report!(profile, attempt, report)
        IO.puts(Jason.encode!(report, pretty: true))

        if report.measurement_complete? do
          {:cont, [report | acc]}
        else
          {:halt, [report | acc]}
        end
      end)
      |> Enum.reverse()

    batch_report = %{
      profile: profile,
      required_attempts: @attempts_per_profile,
      completed_attempts: Enum.count(reports, & &1.measurement_complete?),
      batch_complete?:
        length(reports) == @attempts_per_profile and
          Enum.all?(reports, & &1.measurement_complete?),
      eligible_for_s0_contract_review?:
        length(reports) == @attempts_per_profile and
          Enum.all?(reports, fn report ->
            report.measurement_complete? and report.candidate_invariants_satisfied?
          end),
      numeric_threshold_proposed?: false,
      attempts: Enum.map(reports, & &1.attempt)
    }

    File.write!(
      Path.join(@report_root, "#{profile}-batch.json"),
      Jason.encode!(batch_report, pretty: true)
    )

    IO.puts(Jason.encode!(batch_report, pretty: true))

    unless batch_report.batch_complete? do
      System.halt(2)
    end

    :ok
  end

  defp refuse_existing_batch!(profile) do
    paths =
      Enum.map(1..@attempts_per_profile, fn attempt ->
        Path.join(@report_root, "#{profile}-#{attempt}.json")
      end) ++ [Path.join(@report_root, "#{profile}-batch.json")]

    case Enum.find(paths, &File.exists?/1) do
      nil -> :ok
      path -> raise "refusing to overwrite prior measurement evidence: #{path}"
    end
  end

  defp verify_database_version! do
    {:ok, %{rows: [[database, server_version, version_num]]}} =
      Ecto.Adapters.SQL.query(
        Store.DirectRepo,
        "SELECT current_database(), current_setting('server_version'), current_setting('server_version_num')::integer",
        []
      )

    unless version_num == 1_600_15 do
      raise "measurement requires PostgreSQL 16.15; connected to #{server_version} (#{database})"
    end

    unless database == System.get_env("PGDATABASE", "store_test") do
      raise "connected to unexpected measurement database #{inspect(database)}"
    end
  end

  defp configure_repositories! do
    port = String.to_integer(System.fetch_env!("PGPORT"))
    hostname = System.fetch_env!("PGHOST")
    username = System.get_env("PGUSER", "postgres")
    password = System.get_env("PGPASSWORD", "postgres")
    database = System.get_env("PGDATABASE", "store_test")

    repo_config =
      Application.fetch_env!(:store, Store.Repo)
      |> Keyword.merge(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: @repo_pool_size,
        prepare: :unnamed,
        queue_target: 10_000,
        queue_interval: 10_000,
        timeout: 60_000
      )
      |> put_application_name(@repo_application_name)

    direct_config =
      Application.fetch_env!(:store, Store.DirectRepo)
      |> Keyword.merge(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: @direct_repo_pool_size,
        queue_target: 10_000,
        queue_interval: 10_000,
        timeout: 60_000
      )
      |> put_application_name(@direct_application_name)

    Application.put_env(:store, Store.Repo, repo_config)
    Application.put_env(:store, Store.DirectRepo, direct_config)

    Application.put_env(:store, Oban,
      repo: Store.DirectRepo,
      testing: :manual,
      plugins: false,
      queues: false
    )
  end

  defp put_application_name(config, application_name) do
    parameters =
      config
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:application_name, application_name)

    Keyword.put(config, :parameters, parameters)
  end

  defp run_attempt(profile, attempt) do
    Process.put({__MODULE__, :stage}, :fixture_setup)
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    try do
      fixture = create_fixture!(profile, attempt)
      orders = Enum.map(1..@caller_count, fn _ -> create_order!() end)
      sampler = start_sampler!()

      cohort_started_us = System.monotonic_time(:microsecond)
      Process.put({__MODULE__, :stage}, :cohort)
      send(sampler.pid, {:begin_cohort, sampler.ref, cohort_started_us})

      {caller_rows, task_exit_reasons, cohort_finished_us} =
        run_cohort(orders, fixture.variant_id, sampler)

      Process.put({__MODULE__, :caller_rows}, caller_rows)
      Process.put({__MODULE__, :task_exit_reasons}, task_exit_reasons)

      Process.put(
        {__MODULE__, :cohort_duration_ms},
        (cohort_finished_us - cohort_started_us) / 1_000
      )

      sampling =
        receive do
          {:sampler_complete, ref, result} when ref == sampler.ref -> result
          {:sampler_failed, ref, reason} when ref == sampler.ref -> {:sampler_error, reason}
        after
          @drain_observation_cap_ms + 10_000 -> {:sampler_error, :sampler_response_timeout}
        end

      case sampling do
        {:sampler_error, reason} ->
          %{
            profile: profile,
            attempt: attempt,
            started_at_utc: started_at,
            reached_cohort?: true,
            measurement_complete?: false,
            measurement_error: inspect(reason),
            caller_count: length(caller_rows),
            callers: caller_rows,
            cohort_duration_ms: Process.get({__MODULE__, :cohort_duration_ms}),
            task_exit_count: length(task_exit_reasons),
            task_exits: Enum.map(task_exit_reasons, &inspect/1),
            final_state_available?: false
          }

        sample_result ->
          finalize_report(
            profile,
            attempt,
            started_at,
            fixture,
            caller_rows,
            task_exit_reasons,
            cohort_started_us,
            cohort_finished_us,
            Map.merge(sample_result, %{
              sampler_backend_pid: sampler.backend_pid,
              deadlock_counter_before: sampler.deadlocks_baseline
            })
          )
      end
    rescue
      error ->
        %{
          profile: profile,
          attempt: attempt,
          started_at_utc: started_at,
          reached_cohort?: Process.get({__MODULE__, :stage}) == :cohort,
          measurement_complete?: false,
          failed_stage: Process.get({__MODULE__, :stage}),
          error_type: inspect(error.__struct__),
          error_message: Exception.message(error),
          caller_count: length(Process.get({__MODULE__, :caller_rows}, [])),
          callers: Process.get({__MODULE__, :caller_rows}, []),
          cohort_duration_ms: Process.get({__MODULE__, :cohort_duration_ms}),
          task_exits: Process.get({__MODULE__, :task_exit_reasons}, []) |> Enum.map(&inspect/1),
          final_state_available?: false
        }
    catch
      kind, reason ->
        %{
          profile: profile,
          attempt: attempt,
          started_at_utc: started_at,
          reached_cohort?: Process.get({__MODULE__, :stage}) == :cohort,
          measurement_complete?: false,
          failed_stage: Process.get({__MODULE__, :stage}),
          caught_kind: inspect(kind),
          caught_reason: inspect(reason),
          caller_count: length(Process.get({__MODULE__, :caller_rows}, [])),
          callers: Process.get({__MODULE__, :caller_rows}, []),
          cohort_duration_ms: Process.get({__MODULE__, :cohort_duration_ms}),
          task_exits: Process.get({__MODULE__, :task_exit_reasons}, []) |> Enum.map(&inspect/1),
          final_state_available?: false
        }
    after
      case Process.delete({__MODULE__, :sampler_connection}) do
        connection when is_pid(connection) -> close_sampler(connection)
        _ -> :ok
      end

      Process.delete({__MODULE__, :stage})
      Process.delete({__MODULE__, :caller_rows})
      Process.delete({__MODULE__, :task_exit_reasons})
      Process.delete({__MODULE__, :cohort_duration_ms})
    end
  end

  defp create_fixture!(profile, attempt) do
    suffix = "#{profile}-#{attempt}-#{System.unique_integer([:positive])}"
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("s0_measure_admin"))
    _ = TestFixtures.assign_role!(admin, :admin)

    product =
      Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "s0-measure-#{suffix}",
          title: "S0 reservation measurement #{suffix}",
          base_variant_sku: "S0-MEASURE-#{suffix}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 50_000
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    variant_id = published.default_variant_id
    inventory_item = Repo.get_by!(InventoryItem, variant_id: variant_id)

    inventory_item
    |> Ash.Changeset.for_update(
      :update_counts,
      %{stock_on_hand: 1, reserved_count: 0, allow_oversell: false},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    %{variant_id: variant_id}
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp start_sampler! do
    {:ok, connection} = Postgrex.start_link(connection_options())

    _ =
      Postgrex.query!(
        connection,
        "SELECT set_config('application_name', $1, false)",
        [@sampler_application_name]
      )

    Process.put({__MODULE__, :sampler_connection}, connection)
    ref = make_ref()
    parent = self()
    {:ok, pid} = Task.start(fn -> sampler_loop(parent, ref, connection) end)

    receive do
      {:sampler_ready, ^ref, sampler_pid, deadlocks_baseline} ->
        %{
          pid: pid,
          ref: ref,
          connection: connection,
          backend_pid: sampler_pid,
          deadlocks_baseline: deadlocks_baseline
        }

      {:sampler_failed, ^ref, reason} ->
        raise "out-of-band sampler failed before cohort start: #{inspect(reason)}"
    after
      10_000 -> raise "out-of-band sampler did not become ready"
    end
  end

  defp sampler_loop(parent, ref, connection) do
    try do
      %{rows: [[sampler_pid]]} = Postgrex.query!(connection, "SELECT pg_backend_pid()", [])

      %{rows: [[deadlocks_baseline]]} =
        Postgrex.query!(
          connection,
          "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()",
          []
        )

      send(parent, {:sampler_ready, ref, sampler_pid, deadlocks_baseline})

      receive do
        {:begin_cohort, ^ref, started_us} ->
          cohort_loop(
            parent,
            ref,
            connection,
            sampler_pid,
            deadlocks_baseline,
            started_us,
            []
          )
      end
    rescue
      error ->
        send(parent, {:sampler_failed, ref, {error.__struct__, Exception.message(error)}})
    catch
      kind, reason ->
        send(parent, {:sampler_failed, ref, {kind, reason}})
    end
  end

  defp cohort_loop(
         parent,
         ref,
         connection,
         sampler_pid,
         deadlocks_baseline,
         started_us,
         samples
       ) do
    sample = take_sample!(connection, sampler_pid, started_us, :cohort)
    next_samples = [sample | samples]

    receive do
      {:finish_cohort, ^ref, variant_id, finished_us} ->
        drain_loop(
          parent,
          ref,
          connection,
          sampler_pid,
          deadlocks_baseline,
          started_us,
          finished_us,
          next_samples,
          variant_id,
          System.monotonic_time(:microsecond) +
            @drain_observation_cap_ms * 1_000
        )
    after
      @sample_interval_ms ->
        cohort_loop(
          parent,
          ref,
          connection,
          sampler_pid,
          deadlocks_baseline,
          started_us,
          next_samples
        )
    end
  end

  defp drain_loop(
         parent,
         ref,
         connection,
         sampler_pid,
         deadlocks_baseline,
         started_us,
         finished_us,
         samples,
         variant_id,
         deadline_us
       ) do
    sample = take_sample!(connection, sampler_pid, started_us, :post_cohort)
    next_samples = [sample | samples]
    elapsed_us = System.monotonic_time(:microsecond) - finished_us

    if sample.lock_waiters == 0 or System.monotonic_time(:microsecond) >= deadline_us do
      result =
        snapshot!(connection, variant_id)
        |> Map.merge(%{
          samples: Enum.reverse(next_samples),
          cohort_samples: Enum.filter(Enum.reverse(next_samples), &(&1.phase == "cohort")),
          post_cohort_samples:
            Enum.filter(Enum.reverse(next_samples), &(&1.phase == "post_cohort")),
          drain_observation_elapsed_ms: elapsed_us / 1_000,
          drain_observation_cap_ms: @drain_observation_cap_ms,
          post_cohort_contention_remaining?: sample.lock_waiters > 0,
          deadlock_counter_before: deadlocks_baseline,
          deadlock_counter_after: sample.database_deadlocks
        })

      send(parent, {:sampler_complete, ref, result})
    else
      Process.sleep(@sample_interval_ms)

      drain_loop(
        parent,
        ref,
        connection,
        sampler_pid,
        deadlocks_baseline,
        started_us,
        finished_us,
        next_samples,
        variant_id,
        deadline_us
      )
    end
  end

  defp take_sample!(connection, sampler_pid, started_us, phase) do
    %{rows: [[timestamp, active, waiters, repo_active, repo_waiters, deadlocks]]} =
      Postgrex.query!(connection, @sample_query, [@repo_application_name, sampler_pid])

    %{
      phase: Atom.to_string(phase),
      timestamp_utc: timestamp,
      elapsed_from_cohort_start_ms: (System.monotonic_time(:microsecond) - started_us) / 1_000,
      active_backends: active,
      lock_waiters: waiters,
      repo_active_backends: repo_active,
      repo_lock_waiters: repo_waiters,
      lock_wait_ratio: ratio(waiters, active),
      repo_pool_utilization: ratio(repo_active, @repo_pool_size),
      database_deadlocks: deadlocks
    }
  end

  defp snapshot!(connection, variant_id) do
    %{rows: inventory_rows} =
      Postgrex.query!(connection, @inventory_snapshot_query, [variant_id])

    %{rows: reservation_rows} =
      Postgrex.query!(connection, @reservation_snapshot_query, [variant_id])

    %{
      final_inventory_rows: Enum.map(inventory_rows, fn [json] -> Jason.decode!(json) end),
      final_reservation_rows: Enum.map(reservation_rows, fn [json] -> Jason.decode!(json) end)
    }
  end

  defp run_cohort(orders, variant_id, sampler) do
    parent = self()
    cohort_ref = make_ref()
    sampler_ref = sampler.ref

    stream_results =
      orders
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {order, caller_index} ->
          started_us = System.monotonic_time(:microsecond)

          send(parent, {
            :s0_caller_started,
            sampler_ref,
            cohort_ref,
            caller_index,
            order.id,
            started_us
          })

          outcome =
            try do
              {:returned,
               Orders.reserve_inventory(order.id, [
                 %{variant_id: variant_id, quantity: 1}
               ])}
            rescue
              error -> {:raised, error}
            catch
              kind, reason -> {:caught, kind, reason}
            end

          finished_us = System.monotonic_time(:microsecond)
          elapsed_ms = (finished_us - started_us) / 1_000

          result =
            caller_result(outcome, elapsed_ms)
            |> Map.merge(%{caller_index: caller_index, order_id: order.id})

          send(parent, {
            :s0_caller_finished,
            sampler_ref,
            cohort_ref,
            caller_index,
            order.id,
            result
          })

          result
        end,
        max_concurrency: @caller_count,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({[], []}, fn
        {:ok, result}, {results, exits} -> {[result | results], exits}
        {:exit, reason}, {results, exits} -> {results, [reason | exits]}
      end)

    {results, exits} = stream_results
    cohort_finished_us = System.monotonic_time(:microsecond)

    send(
      sampler.pid,
      {:finish_cohort, sampler.ref, variant_id, cohort_finished_us}
    )

    events = collect_caller_events(sampler_ref, cohort_ref, %{})
    exit_reasons = Enum.reverse(exits)

    caller_rows =
      attach_task_events(
        %{
          stream_results: Enum.reverse(results),
          started_events: Map.get(events, :started, %{}),
          finished_events: Map.get(events, :finished, %{})
        },
        exit_reasons,
        orders
      )

    {caller_rows, exit_reasons, cohort_finished_us}
  end

  defp collect_caller_events(sampler_ref, cohort_ref, events) do
    receive do
      {:s0_caller_started, ^sampler_ref, ^cohort_ref, index, order_id, started_us} ->
        collect_caller_events(
          sampler_ref,
          cohort_ref,
          put_in(events, [:started, index], %{order_id: order_id, started_us: started_us})
        )

      {:s0_caller_finished, ^sampler_ref, ^cohort_ref, index, order_id, result} ->
        collect_caller_events(
          sampler_ref,
          cohort_ref,
          put_in(events, [:finished, index], %{
            order_id: order_id,
            duration_ms: result.duration_ms,
            result: Map.drop(result, [:duration_ms, :caller_index, :order_id])
          })
        )
    after
      0 -> events
    end
  end

  defp caller_result({:returned, {:ok, value}}, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "success",
      return_type: inspect(Map.get(value, :__struct__, :map)),
      return_value: inspect(value, limit: :infinity, printable_limit: 5_000)
    }
  end

  defp caller_result({:returned, {:error, %{code: code} = error}}, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "error",
      error_code: stringify(code),
      error_type: inspect(Map.get(error, :__struct__)),
      error: safe_error_message(error),
      error_value: inspect(error, limit: :infinity, printable_limit: 5_000),
      database_error_code: postgres_error_code(error)
    }
  end

  defp caller_result({:returned, {:error, error}}, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "error_unclassified",
      error_type: inspect(Map.get(error, :__struct__)),
      error: inspect(error, limit: :infinity, printable_limit: 5_000),
      database_error_code: postgres_error_code(error)
    }
  end

  defp caller_result({:raised, error}, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "raised",
      error_type: inspect(error.__struct__),
      error: Exception.message(error),
      database_error_code: postgres_error_code(error)
    }
  end

  defp caller_result({:caught, kind, reason}, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "caught",
      caught_kind: inspect(kind),
      reason: inspect(reason),
      database_error_code: postgres_error_code(reason)
    }
  end

  defp caller_result(other, duration_ms) do
    %{
      duration_ms: duration_ms,
      outcome: "unexpected",
      result: inspect(other, limit: :infinity, printable_limit: 5_000)
    }
  end

  defp attach_task_events(caller_results, task_exit_reasons, orders) do
    started = caller_results.started_events
    finished = caller_results.finished_events
    stream_results = Map.new(caller_results.stream_results, &{&1.caller_index, &1})
    now_us = System.monotonic_time(:microsecond)

    Enum.with_index(orders, 1)
    |> Enum.map(fn {order, index} ->
      start_event = Map.get(started, index)
      finish_event = Map.get(finished, index)
      returned = Map.get(stream_results, index)

      result =
        cond do
          returned ->
            returned

          finish_event ->
            finish_event.result
            |> Map.merge(%{
              caller_index: index,
              order_id: order.id,
              duration_ms: finish_event.duration_ms
            })

          start_event ->
            %{outcome: "task_exit", task_exit_reasons: Enum.map(task_exit_reasons, &inspect/1)}

          true ->
            %{outcome: "not_started"}
        end

      duration_ms =
        cond do
          is_number(result[:duration_ms]) -> result.duration_ms
          start_event -> (now_us - start_event.started_us) / 1_000
          true -> nil
        end

      %{
        caller_index: index,
        order_id: order.id,
        duration_ms: duration_ms,
        duration_source:
          cond do
            is_number(result[:duration_ms]) -> "caller_monotonic"
            start_event -> "observed_until_stream_end_after_exit"
            true -> "not_started"
          end,
        outcome: Map.drop(result, [:duration_ms, :caller_index, :order_id])
      }
    end)
  end

  defp finalize_report(
         profile,
         attempt,
         started_at,
         fixture,
         caller_rows,
         task_exit_reasons,
         cohort_started_us,
         cohort_finished_us,
         sampling
       ) do
    completed_durations =
      for %{duration_ms: duration, duration_source: "caller_monotonic"} <- caller_rows,
          is_number(duration),
          do: duration

    all_durations =
      for %{duration_ms: duration} <- caller_rows, is_number(duration), do: duration

    success_rows = Enum.filter(caller_rows, &(&1.outcome.outcome == "success"))

    error_rows =
      Enum.filter(
        caller_rows,
        &(&1.outcome.outcome in ["error", "error_unclassified", "raised", "caught"])
      )

    loser_code_counts =
      Enum.frequencies_by(error_rows, &Map.get(&1.outcome, :error_code, "UNKNOWN"))

    inventory = List.first(sampling.final_inventory_rows)
    reservations = sampling.final_reservation_rows

    deadlocks_start = sampling.deadlock_counter_before
    deadlocks_end = sampling.deadlock_counter_after
    cohort_samples = sampling.cohort_samples
    contention_samples = Enum.filter(cohort_samples, &(&1.lock_waiters > 0))
    cohort_contention_samples = Enum.filter(cohort_samples, &(&1.repo_lock_waiters > 0))
    active_samples = Enum.filter(cohort_samples, &(&1.repo_active_backends > 0))
    total_duration_ms = (cohort_finished_us - cohort_started_us) / 1_000
    mean_duration_ms = mean(completed_durations)
    lock_ratio_peak = peak(cohort_samples, :lock_wait_ratio, 0.0)
    lock_waiter_peak = peak(cohort_samples, :lock_waiters, 0)
    repo_lock_waiter_peak = peak(cohort_samples, :repo_lock_waiters, 0)
    winner_order_id = success_rows |> List.first() |> then(&if(&1, do: &1.order_id, else: nil))
    reservation_order_ids = Enum.map(reservations, &Map.get(&1, "order_id"))
    counts_by_order = Enum.frequencies(reservation_order_ids)

    timeout_callers = Enum.filter(caller_rows, &database_timeout?/1)
    deadlock_callers = Enum.filter(caller_rows, &database_deadlock?/1)
    all_pool_samples = sampling.samples
    pool_peak = peak(all_pool_samples, :repo_pool_utilization, 0.0)
    cohort_pool_peak = peak(cohort_samples, :repo_pool_utilization, 0.0)

    contention_window_ms =
      case {List.first(cohort_contention_samples), List.last(cohort_contention_samples)} do
        {%{elapsed_from_cohort_start_ms: first}, %{elapsed_from_cohort_start_ms: last}} ->
          max(last - first, 0.0)

        _ ->
          nil
      end

    report = %{
      profile: profile,
      attempt: attempt,
      started_at_utc: started_at,
      measurement_complete?: true,
      reached_cohort?: true,
      postgres_server: "16.15",
      repo_pool_size: @repo_pool_size,
      direct_repo_pool_size: @direct_repo_pool_size,
      caller_count: @caller_count,
      sample_interval_ms: @sample_interval_ms,
      variant_id: fixture.variant_id,
      cohort_duration_ms: total_duration_ms,
      caller_duration_summary_ms: %{
        completed_count: length(completed_durations),
        all_observed_duration_count: length(all_durations),
        mean: mean_duration_ms,
        p50: percentile(completed_durations, 0.50),
        p95: percentile(completed_durations, 0.95),
        p99: percentile(completed_durations, 0.99),
        max: Enum.max(completed_durations, fn -> nil end)
      },
      callers: caller_rows,
      winner_count: length(success_rows),
      winner_order_id: winner_order_id,
      loser_count: length(error_rows),
      loser_error_code_counts: loser_code_counts,
      all_losers_governed?:
        length(error_rows) == @caller_count - 1 and
          Enum.all?(error_rows, fn caller ->
            normalize_code(Map.get(caller.outcome, :error_code)) in @governed_loser_codes
          end),
      governed_loser_codes: @governed_loser_codes,
      task_exits: Enum.map(task_exit_reasons, &inspect/1),
      database_timeouts: Enum.map(timeout_callers, & &1.caller_index),
      database_timeout_count: length(timeout_callers),
      sampler_backend_pid: sampling.sampler_backend_pid,
      deadlock_counter_before: deadlocks_start,
      deadlock_counter_after: deadlocks_end,
      deadlock_delta: max(deadlocks_end - deadlocks_start, 0),
      deadlock_callers: Enum.map(deadlock_callers, & &1.caller_index),
      final_inventory_rows: sampling.final_inventory_rows,
      final_reservation_rows: reservations,
      duplicate_reservation_order_ids:
        counts_by_order
        |> Enum.filter(fn {_order_id, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0)),
      reservation_rows_match_winner?:
        length(reservations) == 1 and
          reservation_order_ids == [winner_order_id] and
          Map.get(List.first(reservations), "quantity") == 1 and
          Map.get(List.first(reservations), "state") == "active",
      no_oversell?:
        is_map(inventory) and
          is_integer(Map.get(inventory, "reserved_count")) and
          is_integer(Map.get(inventory, "stock_on_hand")) and
          Map.get(inventory, "reserved_count") <= Map.get(inventory, "stock_on_hand"),
      candidate_invariants_satisfied?:
        length(caller_rows) == @caller_count and
          length(success_rows) == 1 and
          length(error_rows) == @caller_count - 1 and
          Enum.all?(error_rows, fn caller ->
            normalize_code(Map.get(caller.outcome, :error_code)) in @governed_loser_codes
          end) and
          task_exit_reasons == [] and
          timeout_callers == [] and
          deadlocks_end == deadlocks_start and
          is_map(inventory) and
          Map.get(inventory, "reserved_count") == 1 and
          Map.get(inventory, "stock_on_hand") == 1 and
          Map.get(inventory, "allow_oversell") == false and
          length(reservations) == 1 and
          reservation_order_ids == [winner_order_id] and
          Map.get(List.first(reservations), "quantity") == 1 and
          Map.get(List.first(reservations), "state") == "active" and
          duplicate_reservation_order_ids(reservations) == [] and
          completed_durations != [] and
          mean_duration_ms < @latency_mean_target_ms and
          pool_peak <= @pool_utilization_max_ratio and
          length(cohort_samples) >= 2 and
          length(active_samples) > 0 and
          length(cohort_contention_samples) > 0 and
          not sampling.post_cohort_contention_remaining?,
      sample_count: length(cohort_samples),
      total_sample_count: length(sampling.samples),
      post_cohort_sample_count: length(sampling.post_cohort_samples),
      samples_containing_lock_waits: length(contention_samples),
      proportion_samples_with_lock_waits:
        ratio(length(contention_samples), length(cohort_samples)),
      active_cohort_sample_count: length(active_samples),
      sufficient_observation_coverage?:
        length(cohort_samples) >= 2 and
          length(active_samples) > 0 and
          length(cohort_contention_samples) > 0,
      samples_with_store_repo_lock_waits: length(cohort_contention_samples),
      proportion_samples_with_store_repo_lock_waits:
        ratio(length(cohort_contention_samples), length(cohort_samples)),
      sample_timestamps:
        Enum.map(cohort_samples, fn sample ->
          %{
            timestamp_utc: sample.timestamp_utc,
            elapsed_ms: sample.elapsed_from_cohort_start_ms
          }
        end),
      first_contention_timestamp:
        cohort_contention_samples
        |> List.first()
        |> then(&if(&1, do: &1.timestamp_utc, else: nil)),
      last_contention_timestamp:
        cohort_contention_samples
        |> List.last()
        |> then(&if(&1, do: &1.timestamp_utc, else: nil)),
      peak_waiter_count: lock_waiter_peak,
      peak_store_repo_waiter_count: repo_lock_waiter_peak,
      peak_lock_wait_ratio: lock_ratio_peak,
      peak_store_repo_utilization: pool_peak,
      peak_store_repo_utilization_during_cohort: cohort_pool_peak,
      observed_contention_window_ms: contention_window_ms,
      post_cohort_residual_contention?: sampling.post_cohort_contention_remaining?,
      post_cohort_samples: sampling.post_cohort_samples,
      drain_observation_elapsed_ms: sampling.drain_observation_elapsed_ms,
      drain_observation_cap_ms: sampling.drain_observation_cap_ms,
      existing_latency_gate_mean_target_ms: @latency_mean_target_ms,
      existing_latency_gate_pass?:
        is_number(mean_duration_ms) and mean_duration_ms < @latency_mean_target_ms,
      existing_pool_gate_max_ratio: @pool_utilization_max_ratio,
      existing_pool_gate_pass?: pool_peak <= @pool_utilization_max_ratio,
      ratio_threshold_changed?: false,
      numeric_contention_threshold_proposed?: false
    }

    report
  end

  defp write_report!(profile, attempt, report) do
    path = Path.join(@report_root, "#{profile}-#{attempt}.json")
    File.write!(path, Jason.encode!(report, pretty: true))
    IO.puts("report_file=#{path}")
  end

  defp connection_options do
    [
      hostname: System.fetch_env!("PGHOST"),
      port: String.to_integer(System.fetch_env!("PGPORT")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: System.get_env("PGDATABASE", "store_test"),
      timeout: 60_000,
      connect_timeout: 5_000
    ]
  end

  defp close_sampler(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection, :normal)
  end

  defp postgres_error_code(error) do
    find_postgres_error_code(error)
  end

  defp find_postgres_error_code(%{postgres: %{code: code}}), do: stringify(code)

  defp find_postgres_error_code(value) when is_map(value) do
    Enum.find_value(value, fn {_key, nested} -> find_postgres_error_code(nested) end)
  end

  defp find_postgres_error_code(value) when is_tuple(value) do
    value |> Tuple.to_list() |> find_postgres_error_code()
  end

  defp find_postgres_error_code([head | tail]) do
    find_postgres_error_code(head) || find_postgres_error_code(tail)
  end

  defp find_postgres_error_code([]), do: nil
  defp find_postgres_error_code(_), do: nil

  defp database_timeout?(caller) do
    outcome = caller.outcome
    code = outcome[:database_error_code] |> stringify() |> String.downcase()
    detail = inspect(outcome, limit: :infinity, printable_limit: 5_000) |> String.downcase()

    code in ["57014", "query_canceled", "query_canceled"] or
      String.contains?(detail, "timeout") or
      String.contains?(detail, "timed out")
  end

  defp database_deadlock?(caller) do
    outcome = caller.outcome
    code = outcome[:database_error_code] |> stringify() |> String.downcase()
    detail = inspect(outcome, limit: :infinity, printable_limit: 5_000) |> String.downcase()

    code in ["40p01", "deadlock_detected"] or String.contains?(detail, "deadlock")
  end

  defp safe_error_message(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error, limit: :infinity, printable_limit: 5_000)
  end

  defp duplicate_reservation_order_ids(reservations) do
    reservations
    |> Enum.frequencies_by(&Map.get(&1, "order_id"))
    |> Enum.filter(fn {_order_id, count} -> count > 1 end)
  end

  defp normalize_code(nil), do: nil
  defp normalize_code(code), do: code |> stringify() |> String.upcase()

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp percentile([], _fraction), do: nil

  defp percentile(values, fraction) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * fraction) - 1, 0)
    Enum.at(sorted, index)
  end

  defp peak(samples, key, default) do
    samples
    |> Enum.map(&Map.get(&1, key, default))
    |> Enum.max(fn -> default end)
  end
end

Store.S0ReservationContention.Measurement.run!()
