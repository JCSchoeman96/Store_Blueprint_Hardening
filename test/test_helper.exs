ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Store.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Store.DirectRepo, :manual)

case Store.Support.Redis.flush_db() do
  :ok ->
    :ok

  {:error, reason} ->
    raise """
    Redis is required for the Phase 29 cache and telemetry spine tests but is unreachable.
    Expose Redis to the test environment (for example with Docker -p 6379:6379).
    reason=#{inspect(reason)}
    """
end
