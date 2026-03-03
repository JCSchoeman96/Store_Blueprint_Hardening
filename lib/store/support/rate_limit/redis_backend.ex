defmodule Store.Support.RateLimit.RedisBackend do
  @moduledoc """
  Optional Redis-backed rate limiter seam.

  This backend intentionally does not force a Redis dependency in phase-24.
  Configure `:store, :rate_limit, redis_client: YourRedisClient` to activate.
  The client module must implement:
  - `incr_with_ttl(key, ttl_seconds) :: {:ok, integer()} | {:error, term()}`
  """

  @behaviour Store.Support.RateLimit

  @impl true
  def allow?(scope, key, limit, window_seconds, _opts)
      when (is_atom(scope) or is_binary(scope)) and is_binary(key) and is_integer(limit) and
             limit > 0 and is_integer(window_seconds) and window_seconds > 0 do
    redis_key = redis_key(scope, key)

    with {:ok, client} <- redis_client(),
         {:ok, count} <- client.incr_with_ttl(redis_key, window_seconds) do
      if count <= limit, do: {:ok, :allow}, else: {:ok, :deny}
    end
  end

  def allow?(_scope, _key, _limit, _window_seconds, _opts),
    do: {:error, :invalid_rate_limit_args}

  defp redis_client do
    case Application.get_env(:store, :rate_limit, []) |> Keyword.get(:redis_client) do
      nil -> {:error, :redis_client_not_configured}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_redis_client}
    end
  end

  defp redis_key(scope, key) when is_atom(scope), do: "store:rate_limit:#{scope}:#{key}"
  defp redis_key(scope, key), do: "store:rate_limit:#{scope}:#{key}"
end
