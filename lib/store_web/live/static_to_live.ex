defmodule StoreWeb.Live.StaticToLive do
  @moduledoc false

  @default_jitter_min_ms 25
  @default_jitter_max_ms 150

  @spec schedule_warm_load(Phoenix.LiveView.Socket.t(), term(), keyword()) ::
          {Phoenix.LiveView.Socket.t(), non_neg_integer()}
  def schedule_warm_load(socket, message, opts \\ []) do
    connected? = Phoenix.LiveView.connected?(socket)
    jitter? = Keyword.get(opts, :jitter?, false)
    key = Keyword.get(opts, :key, message)
    jitter_key = {:socket, socket.id || self(), key}

    jitter_ms =
      cond do
        not connected? -> 0
        not jitter? -> 0
        true -> compute_jitter_ms(jitter_key)
      end

    if connected? do
      Process.send_after(self(), message, jitter_ms)
    end

    {socket, jitter_ms}
  end

  @spec emit_mount_telemetry([atom()], integer(), map(), map()) :: :ok
  def emit_mount_telemetry(event, started_at, measurements, metadata)
      when is_list(event) and is_integer(started_at) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(
      event,
      Map.merge(
        %{
          duration: System.monotonic_time() - started_at,
          query_count: 0,
          queue_time: 0,
          query_time: 0,
          decode_time: 0,
          jitter_delay_ms: 0
        },
        measurements
      ),
      metadata
    )
  end

  defp compute_jitter_ms(key) do
    {min_ms, max_ms} = jitter_range()

    if max_ms <= min_ms do
      max(min_ms, 0)
    else
      min_ms + :erlang.phash2(key, max_ms - min_ms + 1)
    end
  end

  defp jitter_range do
    case Application.get_env(:store, :live_warm_load_jitter_ms) do
      {min_ms, max_ms} when is_integer(min_ms) and is_integer(max_ms) ->
        {max(min_ms, 0), max(max_ms, 0)}

      [min: min_ms, max: max_ms] when is_integer(min_ms) and is_integer(max_ms) ->
        {max(min_ms, 0), max(max_ms, 0)}

      _ ->
        {@default_jitter_min_ms, @default_jitter_max_ms}
    end
  end
end
