defmodule Store.PerformanceSmoke.RedisPool do
  @moduledoc false

  use Supervisor

  @state_name __MODULE__.State

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    pool_size = Keyword.fetch!(opts, :pool_size)
    redis_opts = Keyword.fetch!(opts, :redis_opts)

    names = Enum.map(1..pool_size, &worker_name/1)

    workers =
      Enum.map(names, fn name ->
        redix_opts =
          redis_opts |> Keyword.put(:name, name) |> Keyword.put_new(:sync_connect, true)

        Supervisor.child_spec({Redix, redix_opts}, id: name)
      end)

    children =
      workers ++
        [
          %{
            id: @state_name,
            start:
              {Agent, :start_link, [fn -> %{names: names, index: 0} end, [name: @state_name]]}
          }
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec ping() :: :ok | {:error, term()}
  def ping do
    case command(["PING"]) do
      {:ok, "PONG"} -> :ok
      {:ok, other} -> {:error, {:unexpected_ping_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(command) when is_list(command) do
    with {:ok, name} <- next_worker() do
      Redix.command(name, command)
    end
  end

  @spec hgetall_map(String.t()) :: {:ok, map()} | {:error, term()}
  def hgetall_map(key) when is_binary(key) do
    case command(["HGETALL", key]) do
      {:ok, values} when is_list(values) ->
        {:ok, hgetall_list_to_map(values)}

      {:ok, other} ->
        {:error, {:unexpected_hgetall_reply, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec maybe_delete_keys([String.t()]) :: :ok
  def maybe_delete_keys(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.each(fn key ->
      _ = command(["DEL", key])
    end)

    :ok
  end

  @doc """
  Transfer RedisPool lifetime from the setup_all process to an ExUnit on_exit
  teardown contract. The pool remains usable through cleanup and is then
  stopped explicitly.
  """
  @spec transfer_teardown_ownership!(pid(), (-> term())) :: pid()
  def transfer_teardown_ownership!(pid, cleanup_fun)
      when is_pid(pid) and is_function(cleanup_fun, 0) do
    try do
      ExUnit.Callbacks.on_exit({:performance_smoke_redis_pool, pid}, fn ->
        try do
          cleanup_fun.()
        after
          stop_owned!(pid)
        end
      end)

      true = Process.unlink(pid)
      pid
    catch
      kind, reason ->
        _ = stop_owned!(pid)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec stop_owned!(pid()) :: :ok
  def stop_owned!(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      _ = Supervisor.stop(pid, :normal)
    end

    :ok
  end

  defp hgetall_list_to_map(values) do
    values
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [k, v], acc -> Map.put(acc, k, v)
      _other, acc -> acc
    end)
  end

  defp worker_name(index), do: String.to_atom("store_perf_redis_pool_#{index}")

  defp next_worker do
    if Process.whereis(@state_name) do
      try do
        {:ok,
         Agent.get_and_update(@state_name, fn %{names: names, index: index} = state ->
           size = max(length(names), 1)
           next_index = rem(index + 1, size)
           {Enum.at(names, index, hd(names)), %{state | index: next_index}}
         end)}
      catch
        :exit, _reason -> {:error, :redis_pool_not_started}
      end
    else
      {:error, :redis_pool_not_started}
    end
  end
end
