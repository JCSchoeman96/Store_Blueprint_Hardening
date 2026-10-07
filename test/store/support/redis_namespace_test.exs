defmodule Store.Support.RedisNamespaceTest do
  use ExUnit.Case, async: false

  alias Store.Support.Redis

  test "test Redis namespace includes the project, environment, and run id" do
    assert Regex.match?(
             ~r/\Astore_blueprint_hardening:test:[0-9a-f]{32}\z/,
             Redis.key_prefix()
           )
  end

  test "clearing the namespace preserves keys outside this project" do
    run_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    owned_key = Redis.key("namespace_test:#{run_id}")
    other_project_key = "isolated_fixture_project:test:namespace_test:#{run_id}"

    assert {:ok, "OK"} = Redis.command(["SET", owned_key, "owned"])
    assert {:ok, "OK"} = Redis.command(["SET", other_project_key, "external"])

    on_exit(fn ->
      _ = Redis.command(["DEL", owned_key])
      _ = Redis.command(["DEL", other_project_key])
    end)

    assert :ok = Redis.clear_namespace()
    assert {:ok, nil} = Redis.command(["GET", owned_key])
    assert {:ok, "external"} = Redis.command(["GET", other_project_key])
  end
end
