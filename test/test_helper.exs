ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Store.Repo, :manual)

if Store.Support.RateLimit.backend() == Store.Support.RateLimit.RedisBackend do
  case Store.Support.RateLimit.RedixClient.flush_db() do
    :ok ->
      :ok

    {:error, reason} ->
      raise """
      Redis rate-limit backend is enabled for tests but Redis is unreachable.
      Set STORE_RATE_LIMIT_BACKEND=ets to bypass Redis in tests, or expose Redis from Docker with -p 6379:6379.
      reason=#{inspect(reason)}
      """
  end
end
