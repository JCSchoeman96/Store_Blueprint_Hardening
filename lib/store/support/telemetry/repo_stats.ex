defmodule Store.Support.Telemetry.RepoStats do
  @moduledoc """
  Captures repo query telemetry for the current process only.

  The handler executes in the same process that emitted the repo query event,
  which allows safe process-local accumulation without cross-process mutation.
  """

  @event [:store, :repo, :query]

  @type stats :: %{
          query_count: non_neg_integer(),
          queue_time: non_neg_integer(),
          query_time: non_neg_integer(),
          decode_time: non_neg_integer()
        }

  @spec capture((-> result), keyword()) :: {result, stats} when result: term()
  def capture(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    event = Keyword.get(opts, :event, @event)
    ref = make_ref()
    handler_id = "store_repo_stats_#{System.unique_integer([:positive])}"
    marker_key = marker_key(ref)
    stats_key = stats_key(ref)

    Process.put(marker_key, true)
    Process.put(stats_key, empty_stats())

    :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, %{
      marker_key: marker_key,
      stats_key: stats_key
    })

    try do
      result = fun.()
      {result, Process.get(stats_key, empty_stats())}
    after
      :telemetry.detach(handler_id)
      Process.delete(marker_key)
      Process.delete(stats_key)
    end
  end

  @doc false
  def handle_event(_event, measurements, _metadata, %{
        marker_key: marker_key,
        stats_key: stats_key
      }) do
    if Process.get(marker_key) do
      stats = Process.get(stats_key, empty_stats())

      Process.put(stats_key, %{
        query_count: stats.query_count + 1,
        queue_time: stats.queue_time + Map.get(measurements, :queue_time, 0),
        query_time: stats.query_time + Map.get(measurements, :query_time, 0),
        decode_time: stats.decode_time + Map.get(measurements, :decode_time, 0)
      })
    end

    :ok
  end

  defp marker_key(ref), do: {__MODULE__, :marker, ref}
  defp stats_key(ref), do: {__MODULE__, :stats, ref}

  defp empty_stats do
    %{
      query_count: 0,
      queue_time: 0,
      query_time: 0,
      decode_time: 0
    }
  end
end
