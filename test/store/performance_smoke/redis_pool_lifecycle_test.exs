Code.require_file(Path.expand("../../../priv/repo/performance_smoke_redis_pool.exs", __DIR__))

defmodule Store.PerformanceSmoke.RedisPoolLifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.RedisPool

  setup_all do
    {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
    key = "store:perf:lifecycle:#{System.unique_integer([:positive])}"
    assert {:ok, "OK"} = RedisPool.command(["SET", key, "1"])

    # Register the post-teardown assertion first: ExUnit on_exit callbacks run
    # in reverse registration order.
    on_exit(:assert_redis_pool_stopped, fn ->
      assert Process.whereis(RedisPool) == nil
      refute Process.alive?(pid)
    end)

    RedisPool.transfer_teardown_ownership!(pid, fn ->
      assert Process.alive?(pid)
      assert Process.whereis(RedisPool) == pid
      assert {:ok, 1} = RedisPool.command(["DEL", key])
      assert {:ok, 0} = RedisPool.command(["EXISTS", key])
    end)

    {:ok, pid: pid}
  end

  test "setup_all Redis pool remains usable until its cleanup callback", %{pid: pid} do
    assert Process.alive?(pid)
    assert Process.whereis(RedisPool) == pid
    assert {:ok, "PONG"} = RedisPool.command(["PING"])
  end

  defp redis_opts do
    rate_limit_config = Application.get_env(:store, :rate_limit, [])
    redis_config = Keyword.get(rate_limit_config, :redis, [])

    [
      host: Keyword.get(redis_config, :host, "localhost"),
      port: Keyword.get(redis_config, :port, 6379),
      database: Keyword.get(redis_config, :database, 1),
      username: Keyword.get(redis_config, :username),
      password: Keyword.get(redis_config, :password),
      ssl: Keyword.get(redis_config, :ssl, false),
      sync_connect: true
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
