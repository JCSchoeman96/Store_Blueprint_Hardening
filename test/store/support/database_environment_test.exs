defmodule Store.Support.DatabaseEnvironmentTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL

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
end
