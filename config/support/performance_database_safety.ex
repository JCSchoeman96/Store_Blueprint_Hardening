defmodule Store.Config.PerformanceDatabaseSafety do
  @moduledoc false

  @performance_database "store_blueprint_perf"

  @workstation_dev_postgres_port 55_432
  @workstation_test_postgres_port 55_433
  @workstation_dev_redis_port 56_379
  @workstation_test_redis_port 56_380

  @ecto_sql_module Module.concat([Ecto, Adapters, SQL])

  @spec performance_database_name() :: String.t()
  def performance_database_name, do: @performance_database

  @spec allowed_performance_database?(String.t()) :: boolean()
  def allowed_performance_database?(database) when is_binary(database) do
    database == @performance_database
  end

  def allowed_performance_database?(_), do: false

  def validate!(performance_database, test_database, postgres_endpoint, redis_endpoint, ci?)
      when is_binary(performance_database) and performance_database != "" do
    unless allowed_performance_database?(performance_database) do
      raise ArgumentError,
            "STORE_PERF_DATABASE_NAME must be exactly #{@performance_database} (got #{inspect(performance_database)})"
    end

    shared_test_database? =
      performance_database == test_database or
        String.starts_with?(performance_database, "store_blueprint_test")

    if performance_database == "store_blueprint_dev" or shared_test_database? do
      raise ArgumentError,
            "STORE_PERF_DATABASE_NAME must be isolated from the shared DEV and TEST databases"
    end

    validate_postgres_endpoint!(postgres_endpoint, ci?)
    validate_redis_endpoint!(redis_endpoint, ci?)

    performance_database
  end

  def validate!(_performance_database, _test_database, _postgres_endpoint, _redis_endpoint, _ci?) do
    raise ArgumentError, "STORE_PERF_DATABASE_NAME must name a project-isolated database"
  end

  @doc false
  @spec assert_destructive_cleanup_databases_match!(String.t(), String.t()) :: :ok
  def assert_destructive_cleanup_databases_match!(configured_database, connected_database)
      when is_binary(configured_database) and is_binary(connected_database) do
    unless allowed_performance_database?(configured_database) do
      raise ArgumentError,
            "destructive performance smoke cleanup refused: repo database #{inspect(configured_database)} is not the contracted performance database #{@performance_database}"
    end

    if connected_database == configured_database and
         allowed_performance_database?(connected_database) do
      :ok
    else
      raise ArgumentError,
            "destructive performance smoke cleanup refused: connected database #{inspect(connected_database)} does not match configured performance database #{inspect(configured_database)}"
    end
  end

  @spec assert_destructive_cleanup_allowed!(module()) :: :ok
  def assert_destructive_cleanup_allowed!(repo) when is_atom(repo) do
    configured_database = repo.config()[:database]

    unless is_binary(configured_database) and allowed_performance_database?(configured_database) do
      raise ArgumentError,
            "destructive performance smoke cleanup refused: repo database #{inspect(configured_database)} is not the contracted performance database #{@performance_database}"
    end

    case Code.ensure_loaded(@ecto_sql_module) do
      {:module, _} ->
        case apply(@ecto_sql_module, :query!, [repo, "SELECT current_database()", []]) do
          %{rows: [[connected_database]]} ->
            assert_destructive_cleanup_databases_match!(configured_database, connected_database)

          other ->
            raise ArgumentError,
                  "destructive performance smoke cleanup refused: unable to read current_database() from #{inspect(repo)} (#{inspect(other)})"
        end

      {:error, _} ->
        raise ArgumentError,
              "destructive performance smoke cleanup refused: Ecto SQL adapter is not available to verify current_database()"
    end
  end

  defp validate_postgres_endpoint!({host, port}, ci?) when is_binary(host) do
    if loopback?(host) and port == @workstation_dev_postgres_port do
      raise ArgumentError,
            "performance PostgreSQL must not use the shared workstation DEV endpoint"
    end

    if not ci? and loopback?(host) and port == @workstation_test_postgres_port do
      raise ArgumentError,
            "performance PostgreSQL must not use the shared workstation TEST endpoint"
    end

    :ok
  end

  defp validate_postgres_endpoint!(_endpoint, _ci?), do: :ok

  defp validate_redis_endpoint!({host, port}, ci?) when is_binary(host) do
    if loopback?(host) and port == @workstation_dev_redis_port do
      raise ArgumentError,
            "performance Redis must not use the shared workstation DEV endpoint"
    end

    if not ci? and loopback?(host) and port == @workstation_test_redis_port do
      raise ArgumentError,
            "performance Redis must not use the shared workstation TEST endpoint"
    end

    :ok
  end

  defp validate_redis_endpoint!(_endpoint, _ci?), do: :ok

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> String.downcase(host) == "localhost"
    end
  end
end
