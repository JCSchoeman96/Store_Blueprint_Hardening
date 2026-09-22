Code.require_file(Path.expand("../../../priv/repo/performance_smoke_redis_pool.exs", __DIR__))

defmodule Store.PerformanceSmoke.RedisPoolLifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.RedisPool

  defmodule LegacyLinkedPool do
    @moduledoc false

    use Supervisor

    @state_name __MODULE__.State

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts) do
      pool_size = Keyword.fetch!(opts, :pool_size)
      redis_opts = Keyword.fetch!(opts, :redis_opts)
      names = Enum.map(1..pool_size, &worker_name/1)

      children =
        Enum.map(names, fn name ->
          redix_opts =
            redis_opts |> Keyword.put(:name, name) |> Keyword.put_new(:sync_connect, true)

          Supervisor.child_spec({Redix, redix_opts}, id: name)
        end) ++
          [
            %{
              id: @state_name,
              start:
                {Agent, :start_link, [fn -> %{names: names, index: 0} end, [name: @state_name]]}
            }
          ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    def command(command) when is_list(command) do
      if Process.whereis(@state_name) do
        name = Agent.get(@state_name, &worker_name_for/1)
        Redix.command(name, command)
      else
        {:error, :redis_pool_not_started}
      end
    catch
      :exit, _reason -> {:error, :redis_pool_not_started}
    end

    defp worker_name(index), do: String.to_atom("store_perf_legacy_redis_pool_#{index}")

    defp worker_name_for(%{names: [name | _]}), do: name
  end

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

  test "legacy linked setup ownership dies before on_exit cleanup" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} =
          LegacyLinkedPool.start_link(pool_size: 1, redis_opts: redis_opts())

        send(parent, {:legacy_pool_started, pid})

        receive do
          :shutdown_owner -> Process.exit(self(), :shutdown)
        end
      end)

    assert_receive {:legacy_pool_started, pid}, 5_000
    pool_ref = Process.monitor(pid)
    send(owner, :shutdown_owner)
    assert_receive {:DOWN, ^pool_ref, :process, ^pid, _reason}, 5_000

    assert {:error, :redis_pool_not_started} =
             LegacyLinkedPool.command(["PING"])
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
