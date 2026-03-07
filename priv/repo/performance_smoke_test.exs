if Mix.env() != :test do
  raise "performance_smoke_test.exs must be run with MIX_ENV=test"
end

if System.get_env("STORE_PERF_SMOKE") != "true" do
  IO.puts(
    "Skipping performance smoke suite. Set STORE_PERF_SMOKE=true to run this standalone gate script."
  )

  System.halt(0)
end

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise """
  performance_smoke_test.exs expects standalone startup.
  Run with: MIX_ENV=test STORE_PERF_SMOKE=true mix run --no-start priv/repo/performance_smoke_test.exs
  """
end

schedulers = max(System.schedulers_online(), 1)
repo_pool_default = min(max(schedulers * 20, 100), 200)

repo_pool_size =
  case System.get_env("STORE_PERF_REPO_POOL_SIZE") do
    nil -> repo_pool_default
    "" -> repo_pool_default
    value -> value |> String.to_integer() |> min(200) |> max(10)
  end

# Override connection pools for stress testing.
# Bypass Ecto.Adapters.SQL.Sandbox — it serializes owner checkouts and is
# designed for correctness, not throughput. Use the real connection pool instead.
repo_config = Application.get_env(:store, Store.Repo, [])

Application.put_env(
  :store,
  Store.Repo,
  Keyword.merge(repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size: repo_pool_size,
    # Keep prepare: :unnamed to match production behavior through PgBouncer.
    # Transaction-mode PgBouncer cannot use server-side prepared statements,
    # so enabling them here would produce artificially fast results.
    prepare: :unnamed,
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

direct_repo_pool = max(div(repo_pool_size, 4), 10)
direct_repo_config = Application.get_env(:store, Store.DirectRepo, [])

Application.put_env(
  :store,
  Store.DirectRepo,
  Keyword.merge(direct_repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size: direct_repo_pool,
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

# Disable Oban plugins and queues during the perf run.
# Cron jobs (inventory expiry, subscription renewals) and the pruner
# would compete for DirectRepo connections during stress tests.
Application.put_env(:store, Oban,
  repo: Store.DirectRepo,
  testing: :manual,
  plugins: false,
  queues: false
)

# Start app after runtime overrides are set (standalone script mode).
{:ok, _} = Application.ensure_all_started(:store)

ExUnit.start(autorun: false)
ExUnit.configure(max_failures: 1, seed: 0)

defmodule Store.PerformanceSmoke.Config do
  @moduledoc false

  defstruct profile: :local_dev,
            api_mean_ms: 100.0,
            checkout_p99_ms: 5_000.0,
            hll_max_rel_error: 0.02,
            concurrency_users: 20,
            thundering_herd_users: 40,
            stampede_requests: 200,
            stampede_max_resource_queries: 1,
            payment_provider: "stripe",
            repo_pool_size: 20,
            redis_pool_size: 10,
            observer_interval_ms: 500,
            lock_wait_max_ratio: 0.10,
            lock_wait_min_active_backends: 10,
            pool_utilization_max_ratio: 0.95,
            benchee_time_seconds: 2,
            benchee_warmup_seconds: 1,
            sample_iterations: 100,
            run_id: "",
            redis_prefix: ""

  @type t :: %__MODULE__{}

  @spec load() :: t()
  def load do
    profile = profile()
    schedulers = max(System.schedulers_online(), 1)

    defaults =
      case profile do
        :full_stress ->
          %{
            concurrency_users: 120,
            thundering_herd_users: 200,
            stampede_requests: 1_000,
            sample_iterations: 250,
            benchee_time_seconds: 5,
            benchee_warmup_seconds: 2
          }

        :ci_gate ->
          %{
            concurrency_users: min(max(schedulers * 14, 40), 100),
            thundering_herd_users: min(max(schedulers * 20, 80), 160),
            stampede_requests: min(max(schedulers * 120, 350), 700),
            sample_iterations: 160,
            benchee_time_seconds: 3,
            benchee_warmup_seconds: 1
          }

        :local_dev ->
          %{
            concurrency_users: min(max(schedulers * 8, 20), 60),
            thundering_herd_users: min(max(schedulers * 10, 40), 100),
            stampede_requests: min(max(schedulers * 40, 150), 400),
            sample_iterations: 90,
            benchee_time_seconds: 2,
            benchee_warmup_seconds: 1
          }
      end

    run_id = Integer.to_string(System.unique_integer([:positive]))
    concurrency = Map.fetch!(defaults, :concurrency_users)
    # Scale Redis pool to ~1:2 with concurrency to prevent Redix queue contention.
    # At 120 concurrent users with only 20 Redis connections, 100 users queue.
    redis_pool_default = min(max(10, max(schedulers * 4, div(concurrency, 2))), 80)

    %__MODULE__{
      profile: profile,
      api_mean_ms: env_float("STORE_PERF_API_MEAN_MS", 100.0),
      checkout_p99_ms: env_float("STORE_PERF_CHECKOUT_P99_MS", 5_000.0),
      hll_max_rel_error: env_float("STORE_PERF_HLL_MAX_REL_ERROR", 0.02),
      concurrency_users:
        env_int("STORE_PERF_CONCURRENCY_USERS", Map.fetch!(defaults, :concurrency_users)),
      thundering_herd_users:
        env_int(
          "STORE_PERF_THUNDERING_HERD_USERS",
          Map.fetch!(defaults, :thundering_herd_users)
        ),
      stampede_requests:
        env_int("STORE_PERF_STAMPEDE_REQUESTS", Map.fetch!(defaults, :stampede_requests)),
      stampede_max_resource_queries: env_int("STORE_PERF_STAMPEDE_MAX_RESOURCE_QUERIES", 1),
      payment_provider: payment_provider(),
      repo_pool_size: Keyword.get(Store.Repo.config(), :pool_size),
      redis_pool_size: max(env_int("STORE_PERF_REDIS_POOL_SIZE", redis_pool_default), 1),
      observer_interval_ms: env_int("STORE_PERF_OBSERVER_INTERVAL_MS", 500),
      lock_wait_max_ratio: env_float("STORE_PERF_LOCK_WAIT_MAX_RATIO", 0.10),
      lock_wait_min_active_backends: env_int("STORE_PERF_LOCK_WAIT_MIN_ACTIVE_BACKENDS", 10),
      pool_utilization_max_ratio: env_float("STORE_PERF_POOL_UTILIZATION_MAX_RATIO", 0.95),
      benchee_time_seconds:
        env_int("STORE_PERF_BENCHEE_TIME_SECONDS", Map.fetch!(defaults, :benchee_time_seconds)),
      benchee_warmup_seconds:
        env_int(
          "STORE_PERF_BENCHEE_WARMUP_SECONDS",
          Map.fetch!(defaults, :benchee_warmup_seconds)
        ),
      sample_iterations: Map.fetch!(defaults, :sample_iterations),
      run_id: run_id,
      redis_prefix: "store:perf:#{run_id}"
    }
  end

  @spec observer_gate_enforced?(t()) :: boolean()
  def observer_gate_enforced?(%__MODULE__{profile: profile}),
    do: profile in [:ci_gate, :full_stress]

  @spec redis_opts() :: keyword()
  def redis_opts do
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

  defp profile do
    explicit =
      System.get_env("STORE_PERF_PROFILE") ||
        if(System.get_env("GITHUB_ACTIONS") == "true", do: "ci_gate", else: "local_dev")

    case explicit do
      "ci_gate" -> :ci_gate
      "full_stress" -> :full_stress
      "local_dev" -> :local_dev
      other -> raise "invalid STORE_PERF_PROFILE: #{inspect(other)}"
    end
  end

  @spec payment_provider() :: String.t()
  def payment_provider do
    raw_provider =
      case System.get_env("STORE_PERF_PROVIDER") do
        nil ->
          case Store.Payments.Providers.default_purchase_provider_for_ui() do
            nil ->
              case Store.Payments.Providers.enabled_providers() do
                [first | _] -> Atom.to_string(first)
                [] -> nil
              end

            provider ->
              Atom.to_string(provider)
          end

        "" ->
          nil

        value ->
          String.trim(value)
      end

    if is_nil(raw_provider) do
      raise """
      unable to resolve payment provider for performance smoke suite.
      Set STORE_PERF_PROVIDER or configure :store, :payments enabled_providers/default_purchase_provider_for_ui.
      """
    end

    normalized = Store.Payments.Providers.normalize_provider(raw_provider)

    case Store.Payments.Providers.ensure_enabled_provider(normalized) do
      :ok ->
        Atom.to_string(normalized)

      {:error, error} ->
        raise "performance provider #{inspect(raw_provider)} is unsupported/disabled: #{inspect(error)}"
    end
  end

  defp env_int(name, default) when is_integer(default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  defp env_float(name, default) when is_float(default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_float(value)
    end
  end
end

defmodule Store.PerformanceSmoke.Stats do
  @moduledoc false

  @spec describe([number()]) :: %{
          count: non_neg_integer(),
          mean_ms: float(),
          p95_ms: float(),
          p99_ms: float()
        }
  def describe(samples) when is_list(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)

    %{
      count: count,
      mean_ms: mean(sorted),
      p95_ms: percentile(sorted, 95.0),
      p99_ms: percentile(sorted, 99.0)
    }
  end

  @spec mean([number()]) :: float()
  def mean([]), do: 0.0

  def mean(samples) do
    Enum.sum(samples) / length(samples)
  end

  @spec percentile([number()], float()) :: float()
  def percentile([], _pct), do: 0.0

  def percentile(samples, pct) when pct >= 0.0 and pct <= 100.0 do
    count = length(samples)
    rank = max(1, ceil(pct / 100.0 * count))

    samples
    |> Enum.at(rank - 1)
    |> to_float()
  end

  @spec native_to_ms(integer()) :: float()
  def native_to_ms(value) when is_integer(value) do
    System.convert_time_unit(value, :native, :microsecond) / 1_000
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end

defmodule Store.PerformanceSmoke.Reporter do
  @moduledoc false

  @metrics_table :store_performance_smoke_metrics
  @observer_table :store_performance_smoke_observers

  @spec reset() :: :ok
  def reset do
    reset_table(@metrics_table)
    reset_table(@observer_table)

    :ok
  end

  @spec record(map()) :: :ok
  def record(metric) when is_map(metric) do
    key = Map.fetch!(metric, :name)
    :ets.insert(@metrics_table, {key, metric})
    :ok
  end

  @spec record_observer(map()) :: :ok
  def record_observer(summary) when is_map(summary) do
    key = Map.fetch!(summary, :name)
    :ets.insert(@observer_table, {key, summary})
    :ok
  end

  @spec all() :: [map()]
  def all do
    table_values(@metrics_table)
  end

  @spec observers() :: [map()]
  def observers do
    table_values(@observer_table)
  end

  @spec print_table([map()]) :: :ok
  def print_table(metrics) do
    IO.puts("\n| Metric | Target | Mean (ms) | p99 (ms) | Result |")
    IO.puts("| --- | --- | --- | --- | --- |")

    Enum.each(metrics, fn metric ->
      target =
        [
          maybe_target("mean", metric[:target_mean_ms]),
          maybe_target("p99", metric[:target_p99_ms])
        ]
        |> Enum.reject(&(&1 == nil))
        |> Enum.join(" / ")

      mean = metric[:mean_ms] |> float_or_dash()
      p99 = metric[:p99_ms] |> float_or_dash()
      result = if metric[:pass], do: "PASS", else: "FAIL"
      IO.puts("| #{metric[:name]} | #{target} | #{mean} | #{p99} | #{result} |")
    end)

    :ok
  end

  @spec print_observer_table([map()]) :: :ok
  def print_observer_table([]), do: :ok

  def print_observer_table(observers) do
    IO.puts("\n| Observer | Peak Lock Wait Ratio | Peak Lock Waiters | Peak Pool Util | Result |")
    IO.puts("| --- | --- | --- | --- | --- |")

    Enum.each(observers, fn observer ->
      lock_wait_ratio = observer[:peak_lock_wait_ratio] |> float_or_dash()
      lock_waiters = observer[:peak_lock_waiters] |> integer_or_dash()
      pool_utilization = observer[:peak_active_backend_utilization] |> float_or_dash()
      result = if observer[:pass], do: "PASS", else: "FAIL"

      IO.puts(
        "| #{observer[:name]} | #{lock_wait_ratio} | #{lock_waiters} | #{pool_utilization} | #{result} |"
      )
    end)

    :ok
  end

  @spec write_json(map()) :: :ok | {:error, term()}
  def write_json(payload) when is_map(payload) do
    File.mkdir_p!("tmp/perf")
    encoded = Jason.encode_to_iodata!(payload, pretty: true)
    File.write("tmp/perf/performance_smoke_report.json", encoded)
  end

  defp reset_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])

      table ->
        :ets.delete_all_objects(table)
    end
  end

  defp table_values(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.map(fn {_k, v} -> v end)
        |> Enum.sort_by(&Map.get(&1, :name))
    end
  end

  defp maybe_target(_label, nil), do: nil
  defp maybe_target(label, value), do: "#{label}<#{value}"

  defp float_or_dash(nil), do: "-"

  defp float_or_dash(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp integer_or_dash(nil), do: "-"
  defp integer_or_dash(value) when is_integer(value), do: Integer.to_string(value)
end

defmodule Store.PerformanceSmoke.Gate do
  @moduledoc false

  import ExUnit.Assertions

  alias Store.PerformanceSmoke.{Reporter, Stats}

  @spec assert_metric!(String.t(), [number()], keyword()) :: :ok
  def assert_metric!(name, samples_ms, opts) when is_binary(name) and is_list(samples_ms) do
    stats = Stats.describe(samples_ms)
    target_mean_ms = Keyword.get(opts, :target_mean_ms)
    target_p99_ms = Keyword.get(opts, :target_p99_ms)

    mean_pass = is_nil(target_mean_ms) or stats.mean_ms <= target_mean_ms
    p99_pass = is_nil(target_p99_ms) or stats.p99_ms <= target_p99_ms
    pass = mean_pass and p99_pass

    Reporter.record(%{
      name: name,
      target_mean_ms: target_mean_ms,
      target_p99_ms: target_p99_ms,
      mean_ms: stats.mean_ms,
      p99_ms: stats.p99_ms,
      pass: pass,
      sample_count: stats.count
    })

    assert pass,
           "latency gate failed for #{name}: mean=#{stats.mean_ms} p99=#{stats.p99_ms} target_mean=#{inspect(target_mean_ms)} target_p99=#{inspect(target_p99_ms)}"

    :ok
  end

  @spec assert_observer_summary!(map()) :: :ok
  def assert_observer_summary!(summary) when is_map(summary) do
    assert summary.pass,
           "observer gate failed for #{summary.name}: peak_lock_wait_ratio=#{summary.peak_lock_wait_ratio} peak_lock_waiters=#{summary.peak_lock_waiters} peak_active_backend_utilization=#{summary.peak_active_backend_utilization} lock_wait_max_ratio=#{summary.lock_wait_max_ratio} lock_wait_min_active_backends=#{summary.lock_wait_min_active_backends} pool_utilization_max_ratio=#{summary.pool_utilization_max_ratio} samples_over_lock_threshold=#{summary.samples_over_lock_threshold} samples_over_pool_threshold=#{summary.samples_over_pool_threshold}"

    :ok
  end
end

defmodule Store.PerformanceSmoke.Observer do
  @moduledoc false

  alias Store.PerformanceSmoke.{Config, Reporter}

  @sample_query """
  SELECT
    COUNT(*) FILTER (WHERE state = 'active')::bigint AS active_backends,
    COUNT(*) FILTER (WHERE state = 'active' AND wait_event_type = 'Lock')::bigint AS lock_waiters
  FROM pg_stat_activity
  WHERE datname = current_database()
    AND backend_type = 'client backend'
    AND pid <> pg_backend_pid()
  """

  @spec capture(String.t(), Config.t(), (-> term())) :: {term(), map()}
  def capture(name, %Config{} = config, fun) when is_binary(name) and is_function(fun, 0) do
    parent = self()
    ref = make_ref()
    {:ok, pid} = Task.start_link(fn -> sample_loop(parent, ref, config, []) end)
    result = fun.()
    send(pid, {:stop, parent, ref})

    samples =
      receive do
        {:observer_samples, ^ref, samples} -> samples
      end

    summary = summarize(name, config, samples)
    Reporter.record_observer(summary)
    {result, summary}
  end

  defp sample_loop(parent, ref, config, acc) do
    sample = sample(config)

    receive do
      {:stop, ^parent, ^ref} ->
        send(parent, {:observer_samples, ref, Enum.reverse([sample | acc])})
    after
      config.observer_interval_ms ->
        sample_loop(parent, ref, config, [sample | acc])
    end
  end

  defp sample(config) do
    %{rows: [[active_backends, lock_waiters]]} =
      Ecto.Adapters.SQL.query!(Store.DirectRepo, @sample_query, [])

    active_backends = parse_count(active_backends)
    lock_waiters = parse_count(lock_waiters)

    %{
      timestamp_ms: System.system_time(:millisecond),
      active_backends: active_backends,
      lock_waiters: lock_waiters,
      lock_wait_ratio: ratio(lock_waiters, active_backends),
      active_backend_utilization: ratio(active_backends, config.repo_pool_size)
    }
  end

  defp summarize(name, config, samples) do
    samples_over_lock_threshold =
      Enum.count(samples, fn sample ->
        sample.active_backends >= config.lock_wait_min_active_backends and
          sample.lock_wait_ratio > config.lock_wait_max_ratio
      end)

    samples_over_pool_threshold =
      Enum.count(samples, fn sample ->
        sample.active_backend_utilization > config.pool_utilization_max_ratio
      end)

    enforced = Config.observer_gate_enforced?(config)

    %{
      name: name,
      pass:
        if(enforced,
          do: samples_over_lock_threshold == 0 and samples_over_pool_threshold == 0,
          else: true
        ),
      enforced: enforced,
      sample_count: length(samples),
      peak_active_backends: peak_value(samples, :active_backends, 0),
      peak_lock_waiters: peak_value(samples, :lock_waiters, 0),
      peak_lock_wait_ratio: peak_value(samples, :lock_wait_ratio, 0.0),
      peak_active_backend_utilization: peak_value(samples, :active_backend_utilization, 0.0),
      samples_over_lock_threshold: samples_over_lock_threshold,
      samples_over_pool_threshold: samples_over_pool_threshold,
      lock_wait_max_ratio: config.lock_wait_max_ratio,
      lock_wait_min_active_backends: config.lock_wait_min_active_backends,
      pool_utilization_max_ratio: config.pool_utilization_max_ratio
    }
  end

  defp peak_value(samples, key, default) do
    samples
    |> Enum.map(&Map.get(&1, key))
    |> Enum.max(fn -> default end)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp parse_count(value) when is_integer(value), do: value
end

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

defmodule Store.PerformanceSmoke.SingleFlightCache do
  @moduledoc false

  @table :store_perf_single_flight_cache

  @spec clear() :: :ok
  def clear do
    table = ensure_table()
    :ets.delete_all_objects(table)
    :ok
  end

  @spec fetch(String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term(), :hit | :miss} | {:error, term()}
  def fetch(key, loader) when is_binary(key) and is_function(loader, 0) do
    table = ensure_table()

    case :ets.lookup(table, key) do
      [{^key, value}] ->
        {:ok, value, :hit}

      _ ->
        :global.trans({{__MODULE__, key}, self()}, fn ->
          case :ets.lookup(table, key) do
            [{^key, value}] ->
              {:ok, value, :hit}

            _ ->
              case loader.() do
                {:ok, value} ->
                  true = :ets.insert(table, {key, value})
                  {:ok, value, :miss}

                {:error, _} = error ->
                  error
              end
          end
        end)
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      table ->
        table
    end
  end
end

defmodule Store.PerformanceSmoke.Mirror do
  @moduledoc false

  use GenServer

  @type waiter :: {GenServer.from(), non_neg_integer()}

  @type state :: %{
          ets_table: atom(),
          redis_hash_key: String.t(),
          processed_updates: non_neg_integer(),
          barrier_waiters: [waiter()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec update_async(String.t(), map()) :: :ok
  def update_async(seat_id, payload) when is_binary(seat_id) and is_map(payload) do
    GenServer.cast(__MODULE__, {:update, seat_id, payload})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec barrier(non_neg_integer(), timeout()) :: :ok
  def barrier(expected_updates, timeout \\ 30_000)
      when is_integer(expected_updates) and expected_updates >= 0 do
    GenServer.call(__MODULE__, {:barrier, expected_updates}, timeout)
  end

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(opts) do
    ets_table = Keyword.fetch!(opts, :ets_table)
    redis_hash_key = Keyword.fetch!(opts, :redis_hash_key)

    case :ets.whereis(ets_table) do
      :undefined ->
        :ets.new(ets_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    {:ok,
     %{
       ets_table: ets_table,
       redis_hash_key: redis_hash_key,
       processed_updates: 0,
       barrier_waiters: []
     }}
  end

  @impl true
  def handle_cast({:update, seat_id, payload}, %{ets_table: table, redis_hash_key: key} = state) do
    value = Jason.encode!(payload)
    :ets.insert(table, {seat_id, value})
    _ = Store.PerformanceSmoke.RedisPool.command(["HSET", key, seat_id, value])

    next_state =
      state
      |> Map.update!(:processed_updates, &(&1 + 1))
      |> reply_ready_waiters()

    {:noreply, next_state}
  end

  @impl true
  def handle_call(:clear, _from, %{ets_table: table, redis_hash_key: key} = state) do
    :ets.delete_all_objects(table)
    _ = Store.PerformanceSmoke.RedisPool.command(["DEL", key])

    Enum.each(state.barrier_waiters, fn {from, _expected} ->
      GenServer.reply(from, {:error, :mirror_reset})
    end)

    {:reply, :ok, %{state | processed_updates: 0, barrier_waiters: []}}
  end

  def handle_call({:barrier, expected_updates}, from, state) do
    if state.processed_updates >= expected_updates do
      {:reply, :ok, state}
    else
      {:noreply, %{state | barrier_waiters: [{from, expected_updates} | state.barrier_waiters]}}
    end
  end

  def handle_call(:snapshot, _from, %{ets_table: table} = state) do
    snapshot =
      table
      |> :ets.tab2list()
      |> Map.new(fn {k, v} -> {k, v} end)

    {:reply, snapshot, state}
  end

  defp reply_ready_waiters(state) do
    {ready, pending} =
      Enum.split_with(state.barrier_waiters, fn {_from, expected_updates} ->
        state.processed_updates >= expected_updates
      end)

    Enum.each(ready, fn {from, _expected_updates} ->
      GenServer.reply(from, :ok)
    end)

    %{state | barrier_waiters: pending}
  end
end

defmodule Store.PerformanceSmoke.Fixtures do
  @moduledoc false

  import Ecto.Query

  alias Store.Catalog.InventoryItem
  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput, CheckoutStartInput}
  alias Store.Orders.Order
  alias Store.Payments
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Pricing.TaxRate
  alias Store.Repo
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.TestFixtures

  @spec checkout_fixture!() :: map()
  def checkout_fixture! do
    {variant_id, _admin, _product} = published_variant_with_admin!()
    _pricing = create_pricing_rules!()

    selection =
      quote_selection!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    {:ok, start_input} = CheckoutStartInput.new(%{})
    {:ok, finalize_input} = CheckoutFinalizeInput.new(%{})

    {:ok, payment_input} =
      CreateIntentForOrderInput.new(%{
        "provider" => Store.PerformanceSmoke.Config.payment_provider()
      })

    %{
      variant_id: variant_id,
      start_input: start_input,
      finalize_input: finalize_input,
      payment_input: payment_input,
      selection: selection,
      shipping_attrs: %{
        "recipient_name" => "Jane Customer",
        "address_line1" => "1 Main St",
        "city" => "San Francisco",
        "country_code" => "US",
        "region_code" => "CA",
        "postal_code" => "94105",
        "phone" => "555-555-1212"
      }
    }
  end

  @spec checkout_flow!(map(), String.t()) :: :ok | {:error, term()}
  def checkout_flow!(fixture, token) when is_map(fixture) and is_binary(token) do
    actor = %{cart_token: token}

    with {:ok, add_input} <- CartItemInput.new(%{"variant_id" => fixture.variant_id, "qty" => 1}),
         {:ok, _cart} <- CartsFacade.add_item_for_user(nil, token, add_input),
         {:ok, start_result} <- Checkout.start_from_cart(nil, token, fixture.start_input),
         {:ok, shipping_input} <-
           CheckoutShippingInput.new(
             Map.merge(fixture.shipping_attrs, %{
               "quote_hash" => fixture.selection.quote_hash,
               "shipping_method_code" => fixture.selection.shipping_method_code
             })
           ),
         {:ok, _checkout_with_shipping} <-
           Checkout.set_shipping(actor, start_result.checkout_key, shipping_input),
         {:ok, _finalized_checkout} <-
           Checkout.finalize_totals(actor, start_result.checkout_key, fixture.finalize_input),
         {:ok, _intent} <-
           Payments.create_intent_for_order(
             actor,
             start_result.checkout_key,
             fixture.payment_input
           ) do
      :ok
    end
  end

  @spec force_inventory!(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def force_inventory!(variant_id, on_hand) do
    inventory_item = Repo.get_by!(InventoryItem, variant_id: variant_id)

    inventory_item
    |> Ash.Changeset.for_update(
      :update_counts,
      %{stock_on_hand: on_hand, reserved_count: 0, allow_oversell: false},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    :ok
  end

  @spec create_order!() :: Order.t()
  def create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp published_variant_with_admin! do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("perf_checkout_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase29-perf-#{System.unique_integer([:positive])}",
          title: "Phase 29 Performance Product",
          base_variant_sku: "P29-SKU-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 50_000
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    {published.default_variant_id, admin, published}
  end

  defp create_pricing_rules! do
    unique = System.unique_integer([:positive])
    method_code = "GROUND-P29-#{unique}"

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: method_code, name: "Ground #{unique}", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{code: "US-CA-P29-#{unique}", country_code: "US", region_code: "CA", active: true},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rate =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_P29_#{unique}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: "USD",
          shipping_cost_minor: 500,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "CA-STANDARD-P29-#{unique}",
          country_code: "US",
          region_code: "CA",
          product_tax_category: "STANDARD",
          rate_basis_points: 800,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})

    :ok
  end

  defp quote_selection!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    %{
      quote_hash: option.quote_hash,
      shipping_method_code: option.shipping_method_code,
      amount_minor: option.amount_minor
    }
  end
end

defmodule Store.PerformanceSmokeTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Store.Catalog.{InventoryItem, StockFastPath}
  alias Store.Orders

  alias Store.PerformanceSmoke.{
    Config,
    Gate,
    Observer,
    RedisPool,
    Reporter,
    SingleFlightCache,
    Stats
  }

  alias Store.PerformanceSmoke.Fixtures
  alias Store.Support.Errors.Error
  alias Store.Repo

  setup_all do
    # Defensive cleanup: detach any stale telemetry handlers from prior crashed runs.
    # If the script was killed mid-test, handlers matching our prefix may linger.
    :telemetry.list_handlers([:store, :repo, :query])
    |> Enum.filter(fn %{id: id} ->
      String.starts_with?(to_string(id), "phase29_perf_repo_query_")
    end)
    |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

    config = Config.load()

    case RedisPool.start_link(pool_size: config.redis_pool_size, redis_opts: Config.redis_opts()) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        raise "unable to start Redis pool: #{inspect(reason)}"
    end

    case RedisPool.ping() do
      :ok ->
        :ok

      {:error, reason} ->
        if config.profile in [:ci_gate, :full_stress] do
          raise "Redis is required for #{config.profile}; ping failed: #{inspect(reason)}"
        else
          raise "Redis warm-layer tests require reachable Redis; ping failed: #{inspect(reason)}"
        end
    end

    mirror_hash_key = "#{config.redis_prefix}:seat_map:mirror"

    {:ok, _mirror_pid} =
      Store.PerformanceSmoke.Mirror.start_link(
        ets_table: :store_perf_mirror,
        redis_hash_key: mirror_hash_key
      )

    :persistent_term.put({__MODULE__, :config}, config)

    on_exit(fn ->
      # Clean up Redis keys created during the run.
      RedisPool.maybe_delete_keys([
        "#{config.redis_prefix}:seat_holds",
        "#{config.redis_prefix}:seat_map",
        "#{config.redis_prefix}:seat_lock",
        "#{config.redis_prefix}:visitors:hll",
        "#{config.redis_prefix}:seat_map:mirror",
        "#{config.redis_prefix}:bench:seat_map",
        "#{config.redis_prefix}:bench:holds",
        "#{config.redis_prefix}:bench:hll"
      ])

      # Clean up database rows created during the run.
      # Without the Sandbox, test data persists — truncate perf-specific tables
      # to prevent unique constraint violations on subsequent runs.
      # Order matters: respect foreign key dependencies (children first).
      tables_to_truncate = [
        "payment_intents",
        "order_line_items",
        "inventory_reservations",
        "checkout_sessions",
        "cart_items",
        "carts",
        "orders",
        "shipping_rate_rules",
        "shipping_zones",
        "shipping_methods",
        "tax_rates",
        "inventory_items",
        "variants",
        "products"
      ]

      Enum.each(tables_to_truncate, fn table ->
        try do
          Ecto.Adapters.SQL.query!(Store.Repo, "TRUNCATE TABLE #{table} CASCADE", [])
        rescue
          _ -> :ok
        end
      end)
    end)

    {:ok, config: config, mirror_hash_key: mirror_hash_key}
  end

  test "benchee micro-benchmarks execute and report", %{config: config} do
    fixture = Fixtures.checkout_fixture!()
    _ = StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])

    File.mkdir_p!("tmp/perf")

    bench_suite =
      Benchee.run(
        %{
          "hot_stock_fast_path" => fn ->
            StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])
          end,
          "cold_stock_fast_path" => fn ->
            StockFastPath.invalidate_variant_ids([fixture.variant_id])
            StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])
          end,
          "redis_hash_set" => fn ->
            _ =
              RedisPool.command([
                "HSET",
                "#{config.redis_prefix}:bench:seat_map",
                "seat:1",
                "held"
              ])
          end,
          "redis_zset_hold" => fn ->
            score = Integer.to_string(System.system_time(:second) + 60)
            member = "u:#{System.unique_integer([:positive])}"
            _ = RedisPool.command(["ZADD", "#{config.redis_prefix}:bench:holds", score, member])
          end,
          "redis_hll_add" => fn ->
            member = "visitor:#{System.unique_integer([:positive])}"
            _ = RedisPool.command(["PFADD", "#{config.redis_prefix}:bench:hll", member])
          end
        },
        warmup: config.benchee_warmup_seconds,
        time: config.benchee_time_seconds,
        formatters: [Benchee.Formatters.Console],
        print: [fast_warning: false],
        save: [path: "tmp/perf/benchee_suite.benchee"]
      )

    Reporter.record(%{
      name: "benchee_micro_benchmarks",
      target_mean_ms: nil,
      target_p99_ms: nil,
      mean_ms: nil,
      p99_ms: nil,
      pass: is_map(bench_suite)
    })

    assert is_map(bench_suite)
  end

  test "hot warm cold latency means remain under configured API threshold", %{config: config} do
    fixture = Fixtures.checkout_fixture!()
    _ = StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])

    hot_samples =
      timed_samples(config.sample_iterations, fn ->
        StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])
      end)

    warm_samples =
      timed_samples(config.sample_iterations, fn ->
        score = Integer.to_string(System.system_time(:second) + 300)
        member = "u:#{System.unique_integer([:positive])}"

        _ = RedisPool.command(["ZADD", "#{config.redis_prefix}:seat_holds", score, member])
        _ = RedisPool.command(["HSET", "#{config.redis_prefix}:seat_map", "seat:1", member])
        _ = RedisPool.command(["ZREM", "#{config.redis_prefix}:seat_holds", member])
      end)

    cold_samples =
      timed_samples(config.sample_iterations, fn ->
        StockFastPath.invalidate_variant_ids([fixture.variant_id])
        StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])
      end)

    Gate.assert_metric!("hot_path_ets", hot_samples, target_mean_ms: config.api_mean_ms)

    Gate.assert_metric!("warm_path_redis", warm_samples, target_mean_ms: config.api_mean_ms)

    Gate.assert_metric!("cold_path_postgres", cold_samples, target_mean_ms: config.api_mean_ms)
  end

  test "checkout concurrency meets mean and p99 thresholds", %{config: config} do
    fixture = Fixtures.checkout_fixture!()

    {{samples, errors}, observer_summary} =
      Observer.capture("checkout_concurrency_observer", config, fn ->
        1..config.concurrency_users
        |> Task.async_stream(
          fn _idx ->
            token = Ash.UUIDv7.generate()

            {result, elapsed_ms} =
              timed(fn ->
                try do
                  Fixtures.checkout_flow!(fixture, token)
                  :ok
                rescue
                  e -> {:error, e}
                end
              end)

            case result do
              :ok -> {:ok, elapsed_ms}
              {:error, reason} -> {:error, reason}
            end
          end,
          max_concurrency: config.concurrency_users,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {:ok, elapsed_ms}}, {durations, errs} -> {[elapsed_ms | durations], errs}
          {:ok, {:error, reason}}, {durations, errs} -> {durations, [reason | errs]}
          {:exit, reason}, {durations, errs} -> {durations, [reason | errs]}
        end)
      end)

    assert errors == [], "checkout concurrency errors: #{inspect(errors)}"

    Gate.assert_metric!("checkout_concurrency", samples,
      # A full 5-step workflow will not average under 100ms
      target_mean_ms: nil,
      target_p99_ms: config.checkout_p99_ms
    )

    Gate.assert_observer_summary!(observer_summary)
  end

  test "seat-hold registry Redis ZSET concurrency remains fast", %{config: config} do
    key = "#{config.redis_prefix}:seat_holds"

    {samples, errors} =
      1..config.concurrency_users
      |> Task.async_stream(
        fn idx ->
          member = "user:#{idx}"
          score = Integer.to_string(System.system_time(:second) + 120)

          {_result, elapsed_ms} =
            timed(fn ->
              _ = RedisPool.command(["ZADD", key, score, member])
              _ = RedisPool.command(["ZREM", key, member])
              :ok
            end)

          {:ok, elapsed_ms}
        end,
        max_concurrency: config.concurrency_users,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, elapsed_ms}}, {durations, errs} -> {[elapsed_ms | durations], errs}
        {:ok, {:error, reason}}, {durations, errs} -> {durations, [reason | errs]}
        {:exit, reason}, {durations, errs} -> {durations, [reason | errs]}
      end)

    assert errors == [], "seat-hold concurrency errors: #{inspect(errors)}"

    Gate.assert_metric!("seat_hold_zset_concurrency", samples, target_mean_ms: config.api_mean_ms)
  end

  test "high-velocity seat map hash updates remain fast", %{config: config} do
    samples =
      timed_samples(config.sample_iterations, fn ->
        seat_id = "seat:#{System.unique_integer([:positive])}"
        payload = Jason.encode!(%{state: "held", updated_at: System.system_time(:millisecond)})
        _ = RedisPool.command(["HSET", "#{config.redis_prefix}:seat_map", seat_id, payload])
      end)

    Gate.assert_metric!("seat_map_hash_high_velocity", samples,
      target_mean_ms: config.api_mean_ms
    )
  end

  test "thundering herd on domain reservation has one winner", %{config: config} do
    fixture = Fixtures.checkout_fixture!()
    :ok = Fixtures.force_inventory!(fixture.variant_id, 1)

    orders = Enum.map(1..config.thundering_herd_users, fn _ -> Fixtures.create_order!() end)

    {{samples, results}, observer_summary} =
      Observer.capture("domain_thundering_herd_observer", config, fn ->
        orders
        |> Task.async_stream(
          fn order ->
            {result, elapsed_ms} =
              timed(fn ->
                Orders.reserve_inventory(order.id, [
                  %{variant_id: fixture.variant_id, quantity: 1}
                ])
              end)

            {elapsed_ms, result}
          end,
          max_concurrency: config.thundering_herd_users,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {elapsed_ms, result}}, {durations, acc} ->
            {[elapsed_ms | durations], [result | acc]}

          {:exit, reason}, {durations, acc} ->
            {durations, [{:error, reason} | acc]}
        end)
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))

    failure_codes =
      results
      |> Enum.map(fn
        {:error, %Error{code: code}} -> code
        {:error, _other} -> "UNKNOWN"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    assert success_count == 1
    assert length(failure_codes) == config.thundering_herd_users - 1

    # Allow a slightly higher mean to account for row-lock serialization
    Gate.assert_metric!("domain_thundering_herd", samples, target_mean_ms: 250.0)
    Gate.assert_observer_summary!(observer_summary)
  end

  test "thundering herd on Redis same seat grants one lock owner", %{config: config} do
    key = "#{config.redis_prefix}:seat_lock"
    _ = RedisPool.command(["DEL", key])

    {samples, winners} =
      1..config.thundering_herd_users
      |> Task.async_stream(
        fn idx ->
          owner = "owner:#{idx}"

          {reply, elapsed_ms} =
            timed(fn ->
              RedisPool.command(["SET", key, owner, "NX", "PX", "30000"])
            end)

          won? = match?({:ok, "OK"}, reply)
          {elapsed_ms, won?}
        end,
        max_concurrency: config.thundering_herd_users,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({[], 0}, fn
        {:ok, {elapsed_ms, true}}, {durations, winner_count} ->
          {[elapsed_ms | durations], winner_count + 1}

        {:ok, {elapsed_ms, false}}, {durations, winner_count} ->
          {[elapsed_ms | durations], winner_count}

        {:exit, _reason}, {durations, winner_count} ->
          {durations, winner_count}
      end)

    assert winners == 1

    Gate.assert_metric!("redis_thundering_herd", samples, target_mean_ms: config.api_mean_ms)
  end

  test "cache stampede uses single-flight and keeps stamped resource query count bounded", %{
    config: config
  } do
    fixture = Fixtures.checkout_fixture!()
    :ok = SingleFlightCache.clear()
    stampede_key = "#{config.redis_prefix}:stampede:#{fixture.variant_id}"

    stamped_variant_id = fixture.variant_id

    filter = fn _event, _measurements, metadata ->
      source = Map.get(metadata, :source)
      params = Map.get(metadata, :params, [])

      is_target_source = source == "inventory_items"
      has_target_variant = contains_param_value?(params, stamped_variant_id)

      is_target_source and has_target_variant
    end

    {{responses, samples}, events} =
      with_repo_query_telemetry(filter, fn ->
        stream_results =
          1..config.stampede_requests
          |> Task.async_stream(
            fn _ ->
              {result, elapsed_ms} =
                timed(fn ->
                  SingleFlightCache.fetch(stampede_key, fn ->
                    value =
                      InventoryItem
                      |> where([i], i.variant_id == ^fixture.variant_id)
                      |> select([i], %{
                        stock_on_hand: i.stock_on_hand,
                        reserved_count: i.reserved_count
                      })
                      |> Store.Repo.one()

                    {:ok, value}
                  end)
                end)

              {result, elapsed_ms}
            end,
            max_concurrency: min(config.stampede_requests, max(config.concurrency_users, 20)),
            ordered: false,
            timeout: :infinity
          )
          |> Enum.to_list()

        parsed =
          Enum.map(stream_results, fn
            {:ok, {result, elapsed_ms}} -> {result, elapsed_ms}
            {:exit, reason} -> {{:error, reason}, 0.0}
          end)

        responses = Enum.map(parsed, &elem(&1, 0))
        samples = Enum.map(parsed, &elem(&1, 1))
        {responses, samples}
      end)

    query_count = length(events)

    if config.stampede_max_resource_queries == 1 do
      assert query_count == 1,
             "stampede single-flight expected exactly 1 resource query, got #{query_count}; events=#{inspect(events)}"
    else
      assert query_count >= 1 and query_count <= config.stampede_max_resource_queries,
             "stampede query bounds failed expected [1..#{config.stampede_max_resource_queries}], got #{query_count}; events=#{inspect(events)}"
    end

    assert Enum.all?(responses, fn
             {:ok, %{stock_on_hand: _, reserved_count: _}, _hit_state} -> true
             _ -> false
           end),
           "unexpected stampede responses: #{inspect(responses)}"

    Gate.assert_metric!("cache_stampede_single_flight", samples,
      target_mean_ms: config.api_mean_ms
    )
  end

  test "HyperLogLog unique visitor tracking stays within relative error bound", %{config: config} do
    hll_key = "#{config.redis_prefix}:visitors:hll"
    _ = RedisPool.command(["DEL", hll_key])

    # HLL is extremely accurate at low volumes — small sample sizes won't trigger
    # the relative error bound we're validating. Scale with profile intensity.
    hll_min_count =
      case config.profile do
        :full_stress -> 50_000
        :ci_gate -> 10_000
        :local_dev -> 5_000
      end

    unique_count = max(hll_min_count, config.concurrency_users * 50)

    samples =
      1..unique_count
      |> Task.async_stream(
        fn idx ->
          member = "visitor:#{idx}"

          {_result, elapsed_ms} =
            timed(fn ->
              RedisPool.command(["PFADD", hll_key, member])
            end)

          elapsed_ms
        end,
        max_concurrency: min(config.concurrency_users, 120),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, elapsed_ms} -> elapsed_ms
        {:exit, _reason} -> 0.0
      end)

    assert {:ok, observed_raw} = RedisPool.command(["PFCOUNT", hll_key])
    observed = parse_int(observed_raw)
    actual = unique_count * 1.0
    rel_error = abs(observed - actual) / actual

    Reporter.record(%{
      name: "hll_relative_error",
      target_mean_ms: nil,
      target_p99_ms: config.hll_max_rel_error,
      mean_ms: rel_error,
      p99_ms: nil,
      pass: rel_error <= config.hll_max_rel_error
    })

    assert rel_error <= config.hll_max_rel_error,
           "HLL relative error #{rel_error} exceeded #{config.hll_max_rel_error}"

    Gate.assert_metric!("hll_update_latency", samples, target_mean_ms: config.api_mean_ms)
  end

  test "cold path saturation includes queue time and avoids timeout errors", %{config: config} do
    fixture = Fixtures.checkout_fixture!()
    stamped_variant_id = fixture.variant_id

    filter = fn _event, _measurements, metadata ->
      source = Map.get(metadata, :source)
      params = Map.get(metadata, :params, [])

      is_target_source = source == "inventory_items"
      has_target_variant = contains_param_value?(params, stamped_variant_id)

      is_target_source and has_target_variant
    end

    {{samples, errors}, events} =
      with_repo_query_telemetry(filter, fn ->
        1..config.concurrency_users
        |> Task.async_stream(
          fn _ ->
            {result, elapsed_ms} =
              timed(fn ->
                StockFastPath.invalidate_variant_ids([fixture.variant_id])
                StockFastPath.sellable_qty_by_variant_ids([fixture.variant_id])
              end)

            case result do
              %{} -> {:ok, elapsed_ms}
              {:error, reason} -> {:error, reason}
              other -> {:error, other}
            end
          end,
          max_concurrency: min(config.concurrency_users, 40),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({[], []}, fn
          {:ok, {:ok, elapsed_ms}}, {durations, errs} -> {[elapsed_ms | durations], errs}
          {:ok, {:error, reason}}, {durations, errs} -> {durations, [reason | errs]}
          {:exit, reason}, {durations, errs} -> {durations, [reason | errs]}
        end)
      end)

    assert errors == [], "cold saturation errors: #{inspect(errors)}"

    combined_db_ms =
      Enum.map(events, fn %{query_time_ms: query_ms, queue_time_ms: queue_ms} ->
        query_ms + queue_ms
      end)

    Gate.assert_metric!("cold_path_saturation_total_db_time", combined_db_ms,
      target_mean_ms: config.api_mean_ms
    )

    Gate.assert_metric!("cold_path_saturation_request_latency", samples,
      target_mean_ms: config.api_mean_ms
    )
  end

  test "write-through mirror matches Redis after quiescent barrier", %{
    config: config,
    mirror_hash_key: mirror_hash_key
  } do
    :ok = Store.PerformanceSmoke.Mirror.clear()
    updates = config.concurrency_users

    _ =
      1..updates
      |> Task.async_stream(
        fn idx ->
          seat_id = "seat:#{idx}"

          Store.PerformanceSmoke.Mirror.update_async(seat_id, %{
            state: if(rem(idx, 2) == 0, do: "held", else: "released"),
            version: idx
          })

          :ok
        end,
        max_concurrency: min(updates, 120),
        ordered: false,
        timeout: :infinity
      )
      |> Stream.run()

    :ok = Store.PerformanceSmoke.Mirror.barrier(updates)

    ets_snapshot = Store.PerformanceSmoke.Mirror.snapshot()
    assert {:ok, redis_snapshot} = RedisPool.hgetall_map(mirror_hash_key)

    assert ets_snapshot == redis_snapshot

    Reporter.record(%{
      name: "write_through_mirror_consistency",
      target_mean_ms: nil,
      target_p99_ms: nil,
      mean_ms: nil,
      p99_ms: nil,
      pass: true
    })
  end

  defp timed(fun) when is_function(fun, 0) do
    started = System.monotonic_time()
    result = fun.()
    elapsed_ms = Stats.native_to_ms(System.monotonic_time() - started)
    {result, elapsed_ms}
  end

  defp timed_samples(iterations, fun) when is_integer(iterations) and iterations > 0 do
    Enum.map(1..iterations, fn _ ->
      {_result, elapsed_ms} = timed(fun)
      elapsed_ms
    end)
  end

  defp with_repo_query_telemetry(filter_fun, fun)
       when is_function(filter_fun, 3) and is_function(fun, 0) do
    ref = make_ref()
    parent = self()
    handler_id = "phase29_perf_repo_query_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:store, :repo, :query],
      fn event, measurements, metadata, %{ref: ref, parent: parent, filter: filter} ->
        if filter.(event, measurements, metadata) do
          send(parent, {ref, %{event: event, measurements: measurements, metadata: metadata}})
        end
      end,
      %{ref: ref, parent: parent, filter: filter_fun}
    )

    try do
      result = fun.()
      {result, drain_query_events(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_events(ref, acc) do
    receive do
      {^ref, %{measurements: measurements, metadata: metadata}} ->
        query_time = measurements[:query_time] || 0
        queue_time = measurements[:queue_time] || 0

        event = %{
          query_time_ms: Stats.native_to_ms(query_time),
          queue_time_ms: Stats.native_to_ms(queue_time),
          source: Map.get(metadata, :source),
          query: Map.get(metadata, :query),
          params: Map.get(metadata, :params, [])
        }

        drain_query_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp contains_param_value?(params, target_value) when is_list(params) do
    match_values = normalize_param_match_values(target_value)
    Enum.any?(params, &param_match?(&1, match_values))
  end

  defp contains_param_value?(_params, _target_value), do: false

  defp param_match?(value, match_values) when is_list(value) do
    Enum.any?(value, &param_match?(&1, match_values))
  end

  defp param_match?(value, match_values), do: value in match_values

  defp normalize_param_match_values(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> [value, dumped]
      :error -> [value]
    end
  end

  defp normalize_param_match_values(value), do: [value]

  defp parse_int(value) when is_integer(value), do: value * 1.0

  defp parse_int(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_integer()
    |> Kernel.*(1.0)
  end
end

:ok = Store.PerformanceSmoke.Reporter.reset()

test_results = ExUnit.run()

failure_count =
  case test_results do
    %{failures: failures} when is_integer(failures) -> failures
    failures when is_integer(failures) -> failures
  end

run_config =
  :persistent_term.get(
    {Store.PerformanceSmokeTest, :config},
    Store.PerformanceSmoke.Config.load()
  )

metrics = Store.PerformanceSmoke.Reporter.all()
observer_summaries = Store.PerformanceSmoke.Reporter.observers()

summary = %{
  generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  profile: run_config.profile,
  thresholds: %{
    api_mean_ms: run_config.api_mean_ms,
    checkout_p99_ms: run_config.checkout_p99_ms,
    hll_max_rel_error: run_config.hll_max_rel_error,
    stampede_max_resource_queries: run_config.stampede_max_resource_queries,
    observer_interval_ms: run_config.observer_interval_ms,
    lock_wait_max_ratio: run_config.lock_wait_max_ratio,
    lock_wait_min_active_backends: run_config.lock_wait_min_active_backends,
    pool_utilization_max_ratio: run_config.pool_utilization_max_ratio
  },
  load: %{
    concurrency_users: run_config.concurrency_users,
    thundering_herd_users: run_config.thundering_herd_users,
    stampede_requests: run_config.stampede_requests,
    repo_pool_size: run_config.repo_pool_size,
    redis_pool_size: run_config.redis_pool_size
  },
  payment_provider: run_config.payment_provider,
  metrics: metrics,
  observer_summaries: observer_summaries,
  status: if(failure_count == 0, do: "pass", else: "fail"),
  test_failures: test_results
}

Store.PerformanceSmoke.Reporter.print_table(metrics)
Store.PerformanceSmoke.Reporter.print_observer_table(observer_summaries)

case Store.PerformanceSmoke.Reporter.write_json(summary) do
  :ok ->
    IO.puts("\nWrote performance report to tmp/perf/performance_smoke_report.json")

  {:error, reason} ->
    IO.puts("\nFailed to write performance report: #{inspect(reason)}")
end

if failure_count == 0 do
  IO.puts("\nPerformance smoke suite passed")
  System.halt(0)
else
  IO.puts("\nPerformance smoke suite failed")
  System.halt(1)
end
