defmodule Store.PerformanceSmoke.ConnectionIdentity do
  @moduledoc false

  @store_repo_application_name "store_perf_repo"
  @direct_repo_application_name "store_perf_direct_repo"

  @spec store_repo_application_name() :: String.t()
  def store_repo_application_name, do: @store_repo_application_name

  @spec direct_repo_application_name() :: String.t()
  def direct_repo_application_name, do: @direct_repo_application_name
end

defmodule Store.PerformanceSmoke.ProviderPhase do
  @moduledoc false

  @table :store_performance_smoke_provider_phase
  @provider_task_event [:store, :checkout, :provider_setup_task]
  @terminal_results [:ok, :provider_error, :task_exit, :timeout]

  @spec start_tracking() :: {:ok, term()}
  def start_tracking do
    ensure_table()

    :ets.insert(@table, [
      {:tracking?, true},
      {:started, 0},
      {:completed, 0},
      {:active, 0}
    ])

    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, @provider_task_event, &__MODULE__.handle_event/4, nil)
    {:ok, handler_id}
  end

  @spec stop_tracking(term()) :: :ok
  def stop_tracking(handler_id) do
    :ok = :telemetry.detach(handler_id)

    ensure_table()
    :ets.insert(@table, {:tracking?, false})
    :ok
  end

  @spec current() :: :pre_provider | :provider_wait | :post_provider | :untracked
  def current do
    ensure_table()

    case :ets.lookup(@table, :tracking?) do
      [{:tracking?, true}] ->
        active = counter(:active)
        started = counter(:started)

        cond do
          active > 0 -> :provider_wait
          started == 0 -> :pre_provider
          true -> :post_provider
        end

      _ ->
        :untracked
    end
  end

  @spec handle_event(list(), map(), map(), term()) :: :ok
  def handle_event(_event, _measurements, %{result: :started}, _config) do
    increment(:started)
    increment(:active)
    :ok
  end

  def handle_event(_event, _measurements, %{result: result}, _config)
      when result in @terminal_results do
    increment(:completed)
    decrement(:active)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])

      _table ->
        @table
    end
  end

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp increment(key), do: :ets.update_counter(@table, key, {2, 1}, {key, 0})
  defp decrement(key), do: :ets.update_counter(@table, key, {2, -1}, {key, 0})
end

defmodule Store.PerformanceSmoke.ObserverContract do
  @moduledoc false

  alias Store.PerformanceSmoke.ConnectionIdentity

  @type expected_scope :: %{
          required(:kind) => :inventory_reservation,
          required(:relation) => String.t(),
          required(:ctid) => String.t()
        }

  @spec uuid_param!(term()) :: <<_::128>>
  def uuid_param!(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, raw_uuid} -> raw_uuid
      :error -> raise ArgumentError, "invalid observer UUID parameter: #{inspect(uuid)}"
    end
  end

  def uuid_param!(uuid),
    do: raise(ArgumentError, "invalid observer UUID parameter: #{inspect(uuid)}")

  @spec provider_wait_pool_gate_pass?(map(), number()) :: boolean()
  def provider_wait_pool_gate_pass?(summary, max_ratio)
      when is_map(summary) and is_number(max_ratio) do
    Map.fetch!(summary, :provider_wait_sample_count) > 0 and
      Map.fetch!(summary, :provider_wait_repo_utilization_peak) <= max_ratio
  end

  @spec connection_populations([map()], pos_integer(), pos_integer(), keyword()) :: map()
  def connection_populations(backend_rows, repo_pool_size, direct_repo_pool_size, opts \\ [])
      when is_list(backend_rows) and is_integer(repo_pool_size) and repo_pool_size > 0 and
             is_integer(direct_repo_pool_size) and direct_repo_pool_size > 0 and is_list(opts) do
    observer_pid = Keyword.get(opts, :observer_pid)

    rows =
      Enum.reject(backend_rows, fn row ->
        not is_nil(observer_pid) and Map.get(row, :pid) == observer_pid
      end)

    active_rows = Enum.filter(rows, &(Map.get(&1, :state) == "active"))
    repo_name = ConnectionIdentity.store_repo_application_name()
    direct_repo_name = ConnectionIdentity.direct_repo_application_name()

    repo_active_backends = Enum.count(active_rows, &(Map.get(&1, :application_name) == repo_name))

    direct_repo_active_backends =
      Enum.count(active_rows, &(Map.get(&1, :application_name) == direct_repo_name))

    total_active_backends = length(active_rows)

    other_active_backends =
      total_active_backends - repo_active_backends - direct_repo_active_backends

    repo_utilization = ratio(repo_active_backends, repo_pool_size)

    %{
      total_active_backends: total_active_backends,
      repo_active_backends: repo_active_backends,
      direct_repo_active_backends: direct_repo_active_backends,
      other_active_backends: other_active_backends,
      repo_pool_size: repo_pool_size,
      direct_repo_pool_size: direct_repo_pool_size,
      repo_utilization: repo_utilization,
      direct_repo_utilization: ratio(direct_repo_active_backends, direct_repo_pool_size),
      provider_pool_metric: %{
        scope: :store_repo,
        numerator: repo_active_backends,
        denominator: repo_pool_size,
        utilization: repo_utilization
      }
    }
  end

  @spec summarize(String.t(), map(), [map()], keyword()) :: map()
  def summarize(name, config, samples, opts \\ [])
      when is_binary(name) and is_map(config) and is_list(samples) and is_list(opts) do
    expected_scope = Keyword.get(opts, :expected_scope)
    classified_samples = Enum.map(samples, &classify_sample(&1, expected_scope))
    drain = normalize_drain(Keyword.get(opts, :drain))
    post_workload_sample = classify_post_workload_sample(drain, expected_scope)
    thresholds = threshold_counts(classified_samples, config)
    {drain_required?, drained?} = drain_state(expected_scope, drain)
    enforced = Keyword.fetch!(opts, :enforced)
    phase_counts = phase_sample_counts(classified_samples)

    %{
      name: name,
      pass: summary_pass?(enforced, thresholds, drained?),
      enforced: enforced,
      sample_count: length(classified_samples),
      peak_active_backends: peak_value(classified_samples, :active_backends, 0),
      peak_total_active_backends:
        peak_value(
          classified_samples,
          :total_active_backends,
          peak_value(classified_samples, :active_backends, 0)
        ),
      peak_repo_active_backends: peak_value(classified_samples, :repo_active_backends, 0),
      peak_direct_repo_active_backends:
        peak_value(classified_samples, :direct_repo_active_backends, 0),
      peak_other_active_backends: peak_value(classified_samples, :other_active_backends, 0),
      peak_lock_waiters: peak_value(classified_samples, :lock_waiters, 0),
      peak_lock_wait_ratio: peak_value(classified_samples, :lock_wait_ratio, 0.0),
      peak_total_lock_waiters: peak_value(classified_samples, :total_lock_waiters, 0),
      peak_expected_reservation_waiters:
        peak_value(classified_samples, :expected_reservation_waiters, 0),
      peak_unexpected_lock_waiters: peak_value(classified_samples, :unexpected_lock_waiters, 0),
      peak_unexpected_lock_wait_ratio:
        peak_value(classified_samples, :unexpected_lock_wait_ratio, 0.0),
      peak_active_backend_utilization:
        peak_value(classified_samples, :active_backend_utilization, 0.0),
      peak_repo_active_backend_utilization:
        peak_value(classified_samples, :repo_active_backend_utilization, 0.0),
      peak_direct_repo_active_backend_utilization:
        peak_value(classified_samples, :direct_repo_active_backend_utilization, 0.0),
      phase_sample_counts: phase_counts,
      provider_wait_sample_count: Map.get(phase_counts, :provider_wait, 0),
      provider_wait_repo_active_backend_peak:
        phase_peak(classified_samples, :provider_wait, :repo_active_backends, 0),
      provider_wait_repo_utilization_peak:
        phase_peak(classified_samples, :provider_wait, :repo_active_backend_utilization, 0.0),
      pre_provider_repo_utilization_peak:
        phase_peak(classified_samples, :pre_provider, :repo_active_backend_utilization, 0.0),
      post_provider_repo_utilization_peak:
        phase_peak(classified_samples, :post_provider, :repo_active_backend_utilization, 0.0),
      outside_provider_wait_repo_active_backend_peak:
        outside_phase_peak(classified_samples, :repo_active_backends, 0),
      outside_provider_wait_repo_utilization_peak:
        outside_phase_peak(classified_samples, :repo_active_backend_utilization, 0.0),
      samples_over_lock_threshold: thresholds.samples_over_lock_threshold,
      samples_over_unexpected_lock_threshold: thresholds.samples_over_unexpected_lock_threshold,
      samples_over_pool_threshold: thresholds.samples_over_pool_threshold,
      expected_contention_enabled?: drain_required?,
      expected_contention_observed?:
        Enum.any?(classified_samples, &(&1.expected_reservation_waiters > 0)),
      post_workload_waiters: post_workload_value(post_workload_sample, :lock_waiters, 0),
      post_workload_expected_reservation_waiters:
        post_workload_value(post_workload_sample, :expected_reservation_waiters, 0),
      post_workload_unexpected_lock_waiters:
        post_workload_value(post_workload_sample, :unexpected_lock_waiters, 0),
      drained?: drained?,
      drain_sample_count: drain.sample_count,
      drain_elapsed_ms: drain.elapsed_ms,
      lock_wait_max_ratio: config.lock_wait_max_ratio,
      lock_wait_min_active_backends: config.lock_wait_min_active_backends,
      pool_utilization_max_ratio: config.pool_utilization_max_ratio
    }
  end

  defp threshold_counts(samples, config) do
    %{
      samples_over_lock_threshold: count_ratio_threshold(samples, :lock_wait_ratio, config),
      samples_over_unexpected_lock_threshold:
        count_ratio_threshold(samples, :unexpected_lock_wait_ratio, config),
      samples_over_pool_threshold:
        Enum.count(samples, &(&1.active_backend_utilization > config.pool_utilization_max_ratio))
    }
  end

  defp count_ratio_threshold(samples, key, config) do
    Enum.count(samples, fn sample ->
      sample.active_backends >= config.lock_wait_min_active_backends and
        Map.get(sample, key, 0.0) > config.lock_wait_max_ratio
    end)
  end

  defp drain_state(expected_scope, drain) do
    required? = not is_nil(expected_scope) or drain.enabled?
    drained? = if required?, do: drain.drained?, else: true
    {required?, drained?}
  end

  defp summary_pass?(false, _thresholds, _drained?), do: true

  defp summary_pass?(true, thresholds, drained?) do
    thresholds.samples_over_unexpected_lock_threshold == 0 and
      thresholds.samples_over_pool_threshold == 0 and drained?
  end

  @spec classify_sample(map(), expected_scope() | nil) :: map()
  def classify_sample(sample, expected_scope) when is_map(sample) do
    counts = classify_waiters(Map.get(sample, :backend_rows, []), expected_scope)
    active_backends = Map.get(sample, :active_backends, 0)

    active_backend_utilization =
      Map.get(
        sample,
        :repo_active_backend_utilization,
        Map.get(sample, :active_backend_utilization, 0.0)
      )

    Map.merge(sample, %{
      lock_waiters: counts.lock_waiters,
      lock_wait_ratio: ratio(counts.lock_waiters, active_backends),
      total_lock_waiters: counts.total_lock_waiters,
      expected_reservation_waiters: counts.expected_reservation_waiters,
      unexpected_lock_waiters: counts.unexpected_lock_waiters,
      unexpected_lock_wait_ratio: ratio(counts.unexpected_lock_waiters, active_backends),
      active_backend_utilization: active_backend_utilization,
      repo_active_backend_utilization: active_backend_utilization
    })
  end

  @spec classify_waiters([map()], expected_scope() | nil) :: map()
  def classify_waiters(rows, expected_scope) when is_list(rows) do
    lock_waiters = Enum.filter(rows, &lock_waiter?/1)

    expected_reservation_waiters =
      Enum.count(lock_waiters, &expected_reservation_waiter?(&1, expected_scope))

    %{
      lock_waiters: length(lock_waiters),
      total_lock_waiters: length(lock_waiters),
      expected_reservation_waiters: expected_reservation_waiters,
      unexpected_lock_waiters: length(lock_waiters) - expected_reservation_waiters
    }
  end

  @spec expected_reservation_waiter?(map(), expected_scope() | nil) :: boolean()
  def expected_reservation_waiter?(row, %{kind: :inventory_reservation} = scope)
      when is_map(row) do
    valid_scope? =
      scope.relation == "inventory_items" and
        is_binary(scope.ctid) and scope.ctid != ""

    valid_scope? and
      Map.get(row, :has_blocker?, false) and
      Map.get(row, :waits_on_target_row?, false) and
      reservation_lock_query?(Map.get(row, :query))
  end

  def expected_reservation_waiter?(_row, _scope), do: false

  @spec reservation_lock_query?(term()) :: boolean()
  def reservation_lock_query?(query) when is_binary(query) do
    normalized_query = String.downcase(query)

    String.contains?(normalized_query, ~s(from "inventory_items")) and
      String.contains?(normalized_query, "for update")
  end

  def reservation_lock_query?(_query), do: false

  defp classify_post_workload_sample(%{post_workload_sample: sample}, expected_scope)
       when is_map(sample),
       do: classify_sample(sample, expected_scope)

  defp classify_post_workload_sample(_drain, _expected_scope), do: nil

  defp normalize_drain(nil),
    do: %{enabled?: false, drained?: true, sample_count: 0, elapsed_ms: 0}

  defp normalize_drain(drain) when is_map(drain) do
    %{
      enabled?: Map.get(drain, :enabled?, true),
      drained?: Map.get(drain, :drained?, false),
      post_workload_sample: Map.get(drain, :post_workload_sample),
      sample_count: Map.get(drain, :sample_count, 0),
      elapsed_ms: Map.get(drain, :elapsed_ms, 0)
    }
  end

  defp post_workload_value(nil, _key, default), do: default
  defp post_workload_value(sample, key, default), do: Map.get(sample, key, default)

  defp phase_sample_counts(samples) do
    Enum.frequencies_by(samples, &Map.get(&1, :phase, :untracked))
  end

  defp phase_peak(samples, phase, key, default) do
    samples
    |> Enum.filter(&(Map.get(&1, :phase, :untracked) == phase))
    |> peak_value(key, default)
  end

  defp outside_phase_peak(samples, key, default) do
    samples
    |> Enum.reject(&(Map.get(&1, :phase, :untracked) == :provider_wait))
    |> peak_value(key, default)
  end

  defp lock_waiter?(row) do
    Map.get(row, :state) == "active" and Map.get(row, :wait_event_type) == "Lock"
  end

  defp peak_value(samples, key, default) do
    samples
    |> Enum.map(&Map.get(&1, key, default))
    |> Enum.max(fn -> default end)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
end
