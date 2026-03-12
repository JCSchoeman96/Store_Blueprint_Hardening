defmodule Store.Perf.CheckoutWriteReport do
  @moduledoc false

  @default_detail_limit 600

  @spec summarize_step_rows([map()], keyword()) :: map()
  def summarize_step_rows(rows, opts \\ []) when is_list(rows) and is_list(opts) do
    sample_cap = Keyword.get(opts, :sample_cap, 20)
    error_rows = Enum.filter(rows, &(&1.status == :error))

    %{
      count: length(rows),
      success_count: Enum.count(rows, &(&1.status == :ok)),
      error_count: length(error_rows),
      mean_duration_ms: average(rows, :duration_ms),
      p95_duration_ms: percentile(rows, :duration_ms, 0.95),
      mean_query_count: average(rows, :query_count),
      p95_query_count: percentile(rows, :query_count, 0.95),
      mean_queue_time_ms: average(rows, :queue_time_ms),
      mean_query_time_ms: average(rows, :query_time_ms),
      error_codes:
        rows |> Enum.map(& &1.error_code) |> Enum.reject(&is_nil/1) |> Enum.frequencies(),
      error_fingerprints:
        error_rows
        |> Enum.map(&failure_fingerprint/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies(),
      p99_duration_ms: percentile(rows, :duration_ms, 0.99),
      p99_query_count: percentile(rows, :query_count, 0.99),
      dominant_cause: dominant_cause(rows),
      sample_errors:
        error_rows
        |> Enum.take(max(sample_cap, 0))
        |> Enum.map(&sample_error/1)
    }
  end

  @spec failure_fingerprint(map()) :: String.t() | nil
  def failure_fingerprint(%{} = row) do
    error_code = Map.get(row, :error_code)
    message = Map.get(row, :message)
    exception_module = Map.get(row, :exception_module)
    checkout_stage = Map.get(row, :checkout_stage)

    if is_nil(error_code) and is_nil(message) and is_nil(exception_module) do
      nil
    else
      row
      |> fingerprint_components(error_code, message, exception_module, checkout_stage)
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
      |> then(&("fp_" <> &1))
    end
  end

  @spec truncate_detail(term(), non_neg_integer()) :: String.t() | nil
  def truncate_detail(detail, limit \\ @default_detail_limit)

  def truncate_detail(nil, _limit), do: nil

  def truncate_detail(detail, limit) when is_binary(detail) and is_integer(limit) and limit > 0 do
    if String.length(detail) > limit, do: String.slice(detail, 0, limit), else: detail
  end

  def truncate_detail(detail, limit) when is_integer(limit) and limit > 0 do
    detail
    |> inspect(limit: :infinity, printable_limit: limit)
    |> truncate_detail(limit)
  end

  defp sample_error(row) do
    %{
      error_code: Map.get(row, :error_code),
      exception_module: Map.get(row, :exception_module),
      message: Map.get(row, :message),
      error_detail: truncate_detail(Map.get(row, :error_detail)),
      failure_fingerprint: failure_fingerprint(row),
      checkout_stage: Map.get(row, :checkout_stage),
      user_index: Map.get(row, :user_index),
      iteration: Map.get(row, :iteration),
      variant_id: Map.get(row, :variant_id),
      duration_ms: Map.get(row, :duration_ms, 0.0),
      query_count: Map.get(row, :query_count, 0),
      queue_time_ms: Map.get(row, :queue_time_ms, 0.0),
      query_time_ms: Map.get(row, :query_time_ms, 0.0),
      decode_time_ms: Map.get(row, :decode_time_ms, 0.0)
    }
  end

  defp fingerprint_components(row, error_code, message, exception_module, checkout_stage) do
    [
      Map.get(row, :step),
      checkout_stage,
      error_code,
      exception_module,
      message
    ]
    |> Enum.map(fn
      nil -> "nil"
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end)
  end

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

  defp dominant_cause([]), do: "unknown"

  defp dominant_cause(rows) do
    mean_duration_ms = average(rows, :duration_ms)
    mean_queue_time_ms = average(rows, :queue_time_ms)
    mean_query_time_ms = average(rows, :query_time_ms)
    mean_query_count = average(rows, :query_count)
    non_db_ms = max(mean_duration_ms - mean_queue_time_ms - mean_query_time_ms, 0)
    step = rows |> List.first() |> Map.get(:step)

    cond do
      db_queue_dominant?(mean_queue_time_ms, mean_query_time_ms) ->
        "db_queue_dominant"

      provider_wait_dominant?(step, non_db_ms, mean_query_time_ms) ->
        "provider_wait_dominant"

      n_plus_one_dominant?(mean_query_count, mean_query_time_ms) ->
        "n_plus_one_dominant"

      db_cpu_dominant?(mean_query_time_ms, mean_duration_ms) ->
        "db_cpu_dominant"

      allocation_dominant?(mean_duration_ms, mean_query_time_ms, mean_queue_time_ms) ->
        "allocation_dominant"

      true ->
        "lock_scope_dominant"
    end
  end

  defp db_queue_dominant?(mean_queue_time_ms, mean_query_time_ms),
    do: mean_queue_time_ms >= max(mean_query_time_ms * 1.5, 25)

  defp provider_wait_dominant?(:create_payment_intent, non_db_ms, mean_query_time_ms),
    do: non_db_ms >= max(mean_query_time_ms * 2, 150)

  defp provider_wait_dominant?(_step, _non_db_ms, _mean_query_time_ms), do: false

  defp n_plus_one_dominant?(mean_query_count, mean_query_time_ms),
    do: mean_query_count >= 8 and mean_query_time_ms >= 40

  defp db_cpu_dominant?(mean_query_time_ms, mean_duration_ms),
    do: mean_query_time_ms >= max(mean_duration_ms * 0.55, 60)

  defp allocation_dominant?(mean_duration_ms, mean_query_time_ms, mean_queue_time_ms),
    do: mean_duration_ms >= 250 and mean_query_time_ms <= 30 and mean_queue_time_ms <= 10
end
