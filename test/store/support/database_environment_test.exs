defmodule Store.Support.DatabaseEnvironmentTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Store.Config.PerformanceDatabaseSafety

  test "both test repos use the non-superuser TEST database" do
    expected_database =
      "store_blueprint_test" <>
        (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

    for repo <- [Store.Repo, Store.DirectRepo] do
      config = repo.config()

      assert config[:hostname] == "127.0.0.1"
      assert config[:port] == 55_433
      assert config[:database] == expected_database
      assert config[:username] == "store_blueprint_test"

      result =
        SQL.query!(
          repo,
          "SELECT current_database(), current_user, role.rolsuper, role.rolcreatedb FROM pg_roles AS role WHERE role.rolname = current_user",
          []
        )

      assert [[^expected_database, "store_blueprint_test", false, true]] = result.rows
    end
  end

  test "performance database rejects shared DEV and TEST databases" do
    assert validate_performance_database("store_blueprint_perf", "store_blueprint_test") ==
             "store_blueprint_perf"

    assert_raise ArgumentError, fn ->
      validate_performance_database("store_blueprint_dev", "store_blueprint_test")
    end

    assert_raise ArgumentError, fn ->
      validate_performance_database("store_blueprint_test928", "store_blueprint_test928")
    end
  end

  test "performance infrastructure rejects shared workstation endpoints" do
    assert_raise ArgumentError, fn ->
      PerformanceDatabaseSafety.validate!(
        "store_blueprint_perf",
        "store_blueprint_test",
        {"127.0.0.1", 55_433},
        {"performance.internal", 6_380},
        false
      )
    end

    assert_raise ArgumentError, fn ->
      PerformanceDatabaseSafety.validate!(
        "store_blueprint_perf",
        "store_blueprint_test",
        {"performance.internal", 5_432},
        {"localhost", 56_380},
        false
      )
    end

    assert PerformanceDatabaseSafety.validate!(
             "store_blueprint_perf",
             "store_blueprint_test",
             {"127.0.0.1", 55_433},
             {"127.0.0.1", 56_380},
             true
           ) == "store_blueprint_perf"
  end

  defp validate_performance_database(performance_database, test_database) do
    PerformanceDatabaseSafety.validate!(
      performance_database,
      test_database,
      {"performance.internal", 5_432},
      {"performance.internal", 6_380},
      false
    )
  end

  test "performance database name is required" do
    assert_raise ArgumentError, fn ->
      PerformanceDatabaseSafety.validate!(
        "",
        "store_blueprint_test",
        {"performance.internal", 5_432},
        {"performance.internal", 6_380},
        false
      )
    end
  end
end
