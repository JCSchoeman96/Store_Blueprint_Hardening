Code.require_file(Path.expand("../../../priv/repo/performance_smoke_redis_pool.exs", __DIR__))

defmodule Store.PerformanceSmoke.RedisPoolTransferOwnershipTest do
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.RedisPool
  alias Store.Support.Redis

  setup do
    stop_pool_if_present()
    on_exit(:stop_pool, &stop_pool_if_present/0)
    :ok
  end

  test "linked owner shutdown stops an untransferred RedisPool" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
        send(parent, {:started, pid})

        receive do
          :shutdown_owner -> Process.exit(self(), :shutdown)
        end
      end)

    assert_receive {:started, pool_pid}, 5_000
    pool_ref = Process.monitor(pool_pid)
    owner_ref = Process.monitor(owner)
    send(owner, :shutdown_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :shutdown}, 5_000
    assert_receive {:DOWN, ^pool_ref, :process, ^pool_pid, _reason}, 5_000
    assert Process.whereis(RedisPool) == nil
    assert {:error, :redis_pool_not_started} = RedisPool.command(["PING"])
  end

  test "transferred ownership permits cleanup while alive and then stops the pool" do
    owned_key = Redis.key("perf:lifecycle:owned:#{System.unique_integer([:positive])}")

    other_project_key =
      "another_project:test:perf:lifecycle:#{System.unique_integer([:positive])}"

    {:ok, pool_pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
    assert {:ok, "OK"} = RedisPool.command(["SET", owned_key, "owned"])
    assert {:ok, "OK"} = RedisPool.command(["SET", other_project_key, "external"])

    on_exit(:assert_pool_stopped, fn ->
      refute Process.alive?(pool_pid)
      assert Process.whereis(RedisPool) == nil
    end)

    RedisPool.transfer_teardown_ownership!(pool_pid, fn ->
      assert Process.alive?(pool_pid)
      assert Process.whereis(RedisPool) == pool_pid
      assert :ok = RedisPool.maybe_delete_keys([owned_key])
      assert {:ok, nil} = RedisPool.command(["GET", owned_key])
      assert {:ok, "external"} = RedisPool.command(["GET", other_project_key])
      assert :ok = RedisPool.maybe_delete_keys([other_project_key])
    end)

    assert Process.alive?(pool_pid)
    assert {:ok, "PONG"} = RedisPool.command(["PING"])
  end

  test "failed on_exit registration stops the unlinked pool" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pool_pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())

        result =
          try do
            RedisPool.transfer_teardown_ownership!(pool_pid, fn -> :ok end)
            :unexpected_success
          rescue
            error -> {:raised, error}
          end

        send(parent, {:transfer_result, self(), pool_pid, result})
      end)

    assert_receive {:transfer_result, ^owner, pool_pid, {:raised, %ArgumentError{}}}, 5_000
    refute Process.alive?(pool_pid)
    assert Process.whereis(RedisPool) == nil
  end

  defp redis_opts do
    rate_limit_config = Application.get_env(:store, :rate_limit, [])
    redis_config = Keyword.get(rate_limit_config, :redis, [])

    [
      host: Keyword.get(redis_config, :host, "127.0.0.1"),
      port: Keyword.get(redis_config, :port, 6379),
      database: Keyword.get(redis_config, :database, 1),
      username: Keyword.get(redis_config, :username),
      password: Keyword.get(redis_config, :password),
      ssl: Keyword.get(redis_config, :ssl, false),
      sync_connect: true
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp stop_pool_if_present do
    case Process.whereis(RedisPool) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          _ = Supervisor.stop(pid, :normal)
        end

        :ok
    end
  rescue
    _ -> :ok
  end
end
