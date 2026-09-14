defmodule Store.PerformanceSmoke.ObserverContract do
  @moduledoc false

  @type expected_scope :: %{
          required(:kind) => :inventory_reservation,
          required(:relation) => String.t(),
          required(:ctid) => String.t()
        }

  @spec uuid_param!(binary()) :: <<_::128>>
  def uuid_param!(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, raw_uuid} -> raw_uuid
      :error -> raise ArgumentError, "invalid observer UUID parameter: #{inspect(uuid)}"
    end
  end

  def uuid_param!(uuid),
    do: raise(ArgumentError, "invalid observer UUID parameter: #{inspect(uuid)}")

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

    %{
      name: name,
      pass: summary_pass?(enforced, thresholds, drained?),
      enforced: enforced,
      sample_count: length(classified_samples),
      peak_active_backends: peak_value(classified_samples, :active_backends, 0),
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

  @spec classify_sample(map(), expected_scope() | nil) :: map()
  def classify_sample(sample, expected_scope) when is_map(sample) do
    counts =
      case Map.get(sample, :backend_rows) do
        rows when is_list(rows) -> classify_waiters(rows, expected_scope)
        _ -> aggregate_counts(sample)
      end

    active_backends = Map.get(sample, :active_backends, 0)
    active_backend_utilization = Map.get(sample, :active_backend_utilization, 0.0)

    Map.merge(sample, %{
      lock_waiters: counts.lock_waiters,
      lock_wait_ratio: ratio(counts.lock_waiters, active_backends),
      total_lock_waiters: counts.total_lock_waiters,
      expected_reservation_waiters: counts.expected_reservation_waiters,
      unexpected_lock_waiters: counts.unexpected_lock_waiters,
      unexpected_lock_wait_ratio: ratio(counts.unexpected_lock_waiters, active_backends),
      active_backend_utilization: active_backend_utilization
    })
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

  defp classify_waiters(rows, expected_scope) do
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

  defp aggregate_counts(sample) do
    lock_waiters = Map.get(sample, :lock_waiters, 0)

    %{
      lock_waiters: lock_waiters,
      total_lock_waiters: lock_waiters,
      expected_reservation_waiters: 0,
      unexpected_lock_waiters: lock_waiters
    }
  end

  defp reservation_lock_query?(query) when is_binary(query) do
    normalized_query = String.downcase(query)

    String.contains?(normalized_query, ~s(from "inventory_items")) and
      String.contains?(normalized_query, "for update")
  end

  defp reservation_lock_query?(_query), do: false

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

  defp summary_pass?(false, _thresholds, _drained?), do: true

  defp summary_pass?(true, thresholds, drained?) do
    thresholds.samples_over_unexpected_lock_threshold == 0 and
      thresholds.samples_over_pool_threshold == 0 and drained?
  end

  defp drain_state(expected_scope, drain) do
    required? = not is_nil(expected_scope) or drain.enabled?
    drained? = if required?, do: drain.enabled? and drain.drained?, else: true
    {required?, drained?}
  end

  defp classify_post_workload_sample(%{post_workload_sample: sample}, expected_scope)
       when is_map(sample),
       do: classify_sample(sample, expected_scope)

  defp classify_post_workload_sample(_drain, _expected_scope), do: nil

  defp normalize_drain(nil),
    do: %{
      enabled?: false,
      drained?: false,
      post_workload_sample: nil,
      sample_count: 0,
      elapsed_ms: 0
    }

  defp normalize_drain(drain) when is_map(drain) do
    %{
      enabled?: Map.get(drain, :enabled?, false),
      drained?: Map.get(drain, :drained?, false),
      post_workload_sample: Map.get(drain, :post_workload_sample),
      sample_count: Map.get(drain, :sample_count, 0),
      elapsed_ms: Map.get(drain, :elapsed_ms, 0)
    }
  end

  defp post_workload_value(nil, _key, default), do: default
  defp post_workload_value(sample, key, default), do: Map.get(sample, key, default)

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
