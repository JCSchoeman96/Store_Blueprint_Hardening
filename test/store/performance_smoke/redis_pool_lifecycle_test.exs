Code.require_file(Path.expand("../../../priv/repo/performance_smoke_redis_pool.exs", __DIR__))

defmodule Store.PerformanceSmoke.RedisPoolLifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.RedisPool

  @state_name RedisPool.State
  @worker_1 :store_perf_redis_pool_1

  setup do
    stop_pool_if_present()
    on_exit(fn -> stop_pool_if_present() end)
    :ok
  end

  test "linked setup-style owner death makes RedisPool unavailable before cleanup" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
        send(parent, {:started, pid})

        receive do
          :exit_owner -> :ok
        end
      end)

    assert_receive {:started, pid}, 5_000
    assert Process.whereis(RedisPool) == pid
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    send(owner, :exit_owner)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

    assert Process.whereis(RedisPool) == nil
    assert Process.whereis(@state_name) == nil
    assert Process.whereis(@worker_1) == nil
    assert {:error, :redis_pool_not_started} = RedisPool.command(["PING"])
  end

  test "transferred ownership keeps RedisPool alive for cleanup then stops deterministically" do
    parent = self()
    key = "store:perf:lifecycle:#{System.unique_integer([:positive])}"

    owner =
      spawn(fn ->
        {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
        true = Process.unlink(pid)
        send(parent, {:started, pid})

        receive do
          :exit_owner -> :ok
        end
      end)

    assert_receive {:started, pid}, 5_000
    owner_ref = Process.monitor(owner)
    send(owner, :exit_owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 5_000

    assert Process.alive?(pid)
    assert Process.whereis(RedisPool) == pid
    assert {:ok, _} = RedisPool.command(["SET", key, "1"])

    assert :ok = RedisPool.maybe_delete_keys([key])
    assert :ok = RedisPool.stop_owned!(pid)

    assert Process.whereis(RedisPool) == nil
    assert Process.whereis(@state_name) == nil
    assert Process.whereis(@worker_1) == nil
    refute Process.alive?(pid)
  end

  test "transfer_teardown_ownership! cleans up while alive and stops via on_exit" do
    key = "store:perf:lifecycle:on-exit:#{System.unique_integer([:positive])}"

    {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
    assert Process.whereis(RedisPool) == pid
    assert {:ok, _} = RedisPool.command(["SET", key, "1"])

    # Register the post-stop assertion first so it runs after the teardown contract
    # (ExUnit on_exit callbacks execute in reverse registration order).
    on_exit(:assert_redis_pool_stopped, fn ->
      assert Process.whereis(RedisPool) == nil
      assert Process.whereis(@state_name) == nil
      assert Process.whereis(@worker_1) == nil
    end)

    RedisPool.transfer_teardown_ownership!(pid, fn ->
      assert Process.whereis(RedisPool) == pid
      assert Process.alive?(pid)
      assert :ok = RedisPool.maybe_delete_keys([key])
    end)

    assert Process.whereis(RedisPool) == pid
  end

  test "transfer_teardown_ownership! fails closed when on_exit cannot be registered" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} = RedisPool.start_link(pool_size: 1, redis_opts: redis_opts())
        send(parent, {:started, pid})

        receive do
          :transfer ->
            try do
              RedisPool.transfer_teardown_ownership!(pid, fn -> :ok end)
              send(parent, :unexpected_success)
            rescue
              error ->
                send(parent, {:raised, error})
            end
        end
      end)

    assert_receive {:started, pid}, 5_000
    send(owner, :transfer)

    assert_receive {:raised, %ArgumentError{}}, 5_000
    refute Process.alive?(pid)
    assert Process.whereis(RedisPool) == nil
    assert Process.whereis(@state_name) == nil
    assert Process.whereis(@worker_1) == nil
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
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
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
