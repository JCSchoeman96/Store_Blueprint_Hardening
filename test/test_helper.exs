ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Store.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Store.DirectRepo, :manual)

case Store.Support.Redis.clear_namespace() do
  :ok ->
    :ok

  {:error, reason} ->
    raise """
    Shared Redis TEST is required for the cache and telemetry spine tests but is unreachable.
    Verify the workstation Redis TEST service at 127.0.0.1:56380.
    reason=#{inspect(reason)}
    """
end
