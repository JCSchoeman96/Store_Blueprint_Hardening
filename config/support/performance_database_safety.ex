defmodule Store.Config.PerformanceDatabaseSafety do
  @moduledoc false

  def validate!(performance_database, test_database, postgres_endpoint, redis_endpoint, ci?)
      when is_binary(performance_database) and performance_database != "" do
    shared_test_database? =
      performance_database == test_database or
        String.starts_with?(performance_database, "store_blueprint_test")

    if performance_database == "store_blueprint_dev" or shared_test_database? do
      raise ArgumentError,
            "STORE_PERF_DATABASE_NAME must be isolated from the shared DEV and TEST databases"
    end

    if not ci? and shared_workstation_endpoint?(postgres_endpoint, [55_432, 55_433]) do
      raise ArgumentError,
            "performance PostgreSQL must not use the shared workstation DEV or TEST endpoint"
    end

    if not ci? and shared_workstation_endpoint?(redis_endpoint, [56_379, 56_380]) do
      raise ArgumentError,
            "performance Redis must not use the shared workstation DEV or TEST endpoint"
    end

    performance_database
  end

  def validate!(_performance_database, _test_database, _postgres_endpoint, _redis_endpoint, _ci?) do
    raise ArgumentError, "STORE_PERF_DATABASE_NAME must name a project-isolated database"
  end

  defp shared_workstation_endpoint?({host, port}, shared_ports) when is_binary(host) do
    port in shared_ports and loopback?(host)
  end

  defp shared_workstation_endpoint?(_endpoint, _shared_ports), do: false

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> String.downcase(host) == "localhost"
    end
  end
end
