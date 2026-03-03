defmodule Store.Support.RateLimit.EtsBackend do
  @moduledoc """
  Fixed-window ETS rate limiter for single-node usage.
  """

  @behaviour Store.Support.RateLimit

  @table :store_rate_limit

  @impl true
  def allow?(scope, key, limit, window_seconds, _opts)
      when (is_atom(scope) or is_binary(scope)) and is_binary(key) and is_integer(limit) and
             limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    table = ensure_table()
    now_sec = System.system_time(:second)
    window_id = div(now_sec, window_seconds)
    entry_key = {scope_key(scope), key, window_id}
    expires_at = (window_id + 1) * window_seconds

    count =
      :ets.update_counter(
        table,
        entry_key,
        {2, 1},
        {entry_key, 0, expires_at}
      )

    maybe_cleanup(table, now_sec)

    if count <= limit, do: {:ok, :allow}, else: {:ok, :deny}
  end

  def allow?(_scope, _key, _limit, _window_seconds, _opts),
    do: {:error, :invalid_rate_limit_args}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      table ->
        table
    end
  end

  defp maybe_cleanup(table, now_sec) do
    # Opportunistic cleanup keeps table growth bounded without a dedicated process.
    if rem(now_sec, 60) == 0 do
      :ets.select_delete(
        table,
        [
          {{{:"$1", :"$2", :"$3"}, :"$4", :"$5"}, [{:<, :"$5", now_sec}], [true]}
        ]
      )
    end

    :ok
  end

  defp scope_key(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_key(scope), do: scope
end
