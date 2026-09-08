defmodule Store.TestSupport.ProviderWaitOwnershipProbe do
  @moduledoc false

  @env_key :provider_wait_ownership_probe
  @waiters_table :store_provider_wait_ownership_waiters
  @default_await_ms 30_000

  @type proof_status :: :proof_passed | :proof_failed | :proof_incomplete
  @type metric_sample :: %{
          sources: [{atom(), pid()}],
          ready_conn_count: non_neg_integer(),
          checkout_queue_length: non_neg_integer(),
          metrics: [map()]
        }

  @type proof :: %{
          status: proof_status(),
          expected_probe_cohort: pos_integer(),
          entered_count: non_neg_integer(),
          baseline: metric_sample() | nil,
          barrier: metric_sample() | nil,
          occupancy_delta: integer() | nil,
          queue_delta: integer() | nil,
          process_local_checked_out_count: non_neg_integer(),
          hold_checkout?: boolean(),
          diagnostic: String.t()
        }

  @spec configure!(keyword()) :: :ok
  def configure!(opts) when is_list(opts) do
    expected_cohort = Keyword.fetch!(opts, :expected_cohort)
    hold_checkout? = Keyword.get(opts, :hold_checkout?, false)
    sampler = Keyword.fetch!(opts, :sampler)
    await_ms = Keyword.get(opts, :await_ms, @default_await_ms)

    if not is_integer(expected_cohort) or expected_cohort < 1 do
      raise ArgumentError, "expected_cohort must be a positive integer"
    end

    if not is_pid(sampler) do
      raise ArgumentError, "sampler must be a pid"
    end

    reset!()

    waiters = :ets.new(@waiters_table, [:named_table, :public, :bag, read_concurrency: true])

    state = %{
      enabled: true,
      expected_cohort: expected_cohort,
      hold_checkout?: hold_checkout?,
      sampler: sampler,
      await_ms: await_ms,
      release_ref: make_ref(),
      entered: :atomics.new(1, []),
      local_checked_out: :atomics.new(1, []),
      waiters: waiters,
      baseline: nil,
      barrier: nil,
      proof: nil
    }

    Application.put_env(:store, @env_key, state)
    :ok
  end

  @spec capture_baseline!() :: metric_sample()
  def capture_baseline! do
    state = fetch_state!()
    baseline = sample_pool_metrics!()
    Application.put_env(:store, @env_key, %{state | baseline: baseline})
    baseline
  end

  @spec maybe_enter_barrier() :: :ok
  def maybe_enter_barrier do
    case Application.get_env(:store, @env_key) do
      %{enabled: true} = state ->
        enter_barrier(state)

      _ ->
        :ok
    end
  end

  @spec await_and_sample!() :: proof()
  def await_and_sample! do
    state = fetch_state!()
    expected = state.expected_cohort

    result =
      receive do
        {:provider_wait_cohort_ready, ^expected} ->
          evaluate_ownership_proof(state)
      after
        state.await_ms ->
          incomplete_proof(
            state,
            "PROVIDER_WAIT_BARRIER_TIMEOUT expected=#{expected} entered=#{entered_count(state)}"
          )
      end

    release_waiters(state)
    put_proof(result)
    result
  end

  @spec release_all!() :: :ok
  def release_all! do
    case Application.get_env(:store, @env_key) do
      %{} = state ->
        broadcast_release(state)
        Application.put_env(:store, @env_key, %{state | enabled: false})
        :ok

      _ ->
        :ok
    end
  end

  @spec reset!() :: :ok
  def reset! do
    safe_ets_delete(@waiters_table)
    Application.delete_env(:store, @env_key)
    :ok
  end

  @spec proof() :: proof() | nil
  def proof do
    case Application.get_env(:store, @env_key) do
      %{proof: proof} -> proof
      _ -> nil
    end
  end

  @spec expected_probe_cohort(pos_integer(), pos_integer()) :: pos_integer()
  def expected_probe_cohort(max_concurrency, users)
      when is_integer(max_concurrency) and max_concurrency >= 1 and is_integer(users) and
             users >= 1 do
    min(max_concurrency, users)
  end

  defp enter_barrier(state) do
    slot = :atomics.add_get(state.entered, 1, 1)

    if slot > state.expected_cohort do
      :ok
    else
      run_barrier_waiter(state, slot)
    end
  end

  defp run_barrier_waiter(state, slot) do
    waiter = fn ->
      true = :ets.insert(state.waiters, {:waiter, self()})

      if Store.Repo.checked_out?() do
        :atomics.add(state.local_checked_out, 1, 1)
      end

      if slot == state.expected_cohort do
        send(state.sampler, {:provider_wait_cohort_ready, state.expected_cohort})
      end

      wait_for_release(state.release_ref)
    end

    if state.hold_checkout? do
      Store.Repo.checkout(fn -> waiter.() end)
    else
      waiter.()
    end

    :ok
  end

  defp wait_for_release(release_ref) do
    receive do
      {:provider_wait_release, ^release_ref} -> :ok
    after
      60_000 ->
        # Fail-closed unlock so a stuck probe cannot deadlock CI forever.
        :ok
    end
  end

  defp evaluate_ownership_proof(state) do
    baseline = state.baseline || capture_baseline_locked!(state)

    case sample_pool_metrics() do
      {:ok, barrier} ->
        if sources_match?(baseline.sources, barrier.sources) do
          occupancy_delta = baseline.ready_conn_count - barrier.ready_conn_count
          queue_delta = barrier.checkout_queue_length - baseline.checkout_queue_length
          local_checked_out = :atomics.get(state.local_checked_out, 1)
          entered = entered_count(state)

          cond do
            entered != state.expected_cohort ->
              incomplete_proof(
                state,
                "PROVIDER_WAIT_COHORT_MISMATCH expected=#{state.expected_cohort} entered=#{entered}"
              )

            occupancy_delta != 0 or queue_delta != 0 or local_checked_out > 0 ->
              %{
                status: :proof_failed,
                expected_probe_cohort: state.expected_cohort,
                entered_count: entered,
                baseline: baseline,
                barrier: barrier,
                occupancy_delta: occupancy_delta,
                queue_delta: queue_delta,
                process_local_checked_out_count: local_checked_out,
                hold_checkout?: state.hold_checkout?,
                diagnostic:
                  "STORE_REPO_OWNERSHIP_RETAINED_DURING_PROVIDER_WAIT occupancy_delta=#{occupancy_delta} queue_delta=#{queue_delta} process_local_checked_out_count=#{local_checked_out}"
              }

            true ->
              %{
                status: :proof_passed,
                expected_probe_cohort: state.expected_cohort,
                entered_count: entered,
                baseline: baseline,
                barrier: barrier,
                occupancy_delta: occupancy_delta,
                queue_delta: queue_delta,
                process_local_checked_out_count: local_checked_out,
                hold_checkout?: state.hold_checkout?,
                diagnostic: "STORE_REPO_OWNERSHIP_RELEASED_DURING_PROVIDER_WAIT"
              }
          end
        else
          incomplete_proof(
            state,
            "PROVIDER_WAIT_POOL_TOPOLOGY_CHANGED baseline=#{inspect(baseline.sources)} barrier=#{inspect(barrier.sources)}"
          )
        end

      {:error, reason} ->
        incomplete_proof(
          state,
          "PROVIDER_WAIT_POOL_METRICS_UNAVAILABLE reason=#{inspect(reason)}"
        )
    end
  end

  defp incomplete_proof(state, diagnostic) do
    %{
      status: :proof_incomplete,
      expected_probe_cohort: state.expected_cohort,
      entered_count: entered_count(state),
      baseline: state.baseline,
      barrier: nil,
      occupancy_delta: nil,
      queue_delta: nil,
      process_local_checked_out_count: :atomics.get(state.local_checked_out, 1),
      hold_checkout?: state.hold_checkout?,
      diagnostic: diagnostic
    }
  end

  defp capture_baseline_locked!(state) do
    baseline = sample_pool_metrics!()
    Application.put_env(:store, @env_key, %{state | baseline: baseline})
    baseline
  end

  defp sample_pool_metrics! do
    case sample_pool_metrics() do
      {:ok, sample} -> sample
      {:error, reason} -> raise "unable to sample Store.Repo pool metrics: #{inspect(reason)}"
    end
  end

  defp sample_pool_metrics do
    with {:ok, sources} <- resolve_pool_sources(),
         {:ok, metrics} <- fetch_metrics(sources) do
      {:ok,
       %{
         sources: Enum.map(sources, &serialize_source/1),
         ready_conn_count: Enum.sum(Enum.map(metrics, & &1.ready_conn_count)),
         checkout_queue_length: Enum.sum(Enum.map(metrics, & &1.checkout_queue_length)),
         metrics: Enum.map(metrics, &serialize_metric/1)
       }}
    end
  end

  defp resolve_pool_sources do
    pool_count = Keyword.get(Store.Repo.config(), :pool_count, 1) || 1
    children = Supervisor.which_children(Store.Repo)

    case {pool_count, children} do
      {1, [{DBConnection.ConnectionPool, pid, :worker, _}]} when is_pid(pid) ->
        {:ok, [{:pool, pid}]}

      {count, [{PartitionSupervisor, supervisor, :supervisor, _}]}
      when is_integer(count) and count > 1 and is_pid(supervisor) ->
        partition_pools =
          for {_id, pid, :worker, _} <- Supervisor.which_children(supervisor), is_pid(pid) do
            {:pool, pid}
          end

        if length(partition_pools) == count do
          {:ok, partition_pools}
        else
          {:error, {:partition_pool_count_mismatch, count, length(partition_pools)}}
        end

      other ->
        {:error, {:unexpected_repo_topology, pool_count, summarize_children(other)}}
    end
  end

  defp summarize_children({_count, children}), do: summarize_children(children)

  defp summarize_children(children) when is_list(children) do
    Enum.map(children, fn
      {id, pid, type, modules} -> {id, is_pid(pid), type, modules}
      other -> other
    end)
  end

  defp fetch_metrics(sources) do
    metrics =
      Enum.map(sources, fn {:pool, pid} ->
        case DBConnection.get_connection_metrics(pid) do
          [%{ready_conn_count: ready, checkout_queue_length: queue, source: source}] ->
            %{
              source: source,
              ready_conn_count: ready,
              checkout_queue_length: queue
            }

          other ->
            {:bad_metrics, pid, other}
        end
      end)

    if Enum.any?(metrics, &match?({:bad_metrics, _, _}, &1)) do
      {:error, metrics}
    else
      {:ok, metrics}
    end
  end

  defp serialize_source({:pool, pid}) when is_pid(pid), do: %{type: "pool", pid: inspect(pid)}

  defp serialize_metric(%{source: source, ready_conn_count: ready, checkout_queue_length: queue}) do
    %{
      source: serialize_metric_source(source),
      ready_conn_count: ready,
      checkout_queue_length: queue
    }
  end

  defp serialize_metric_source({:pool, pid}) when is_pid(pid),
    do: %{type: "pool", pid: inspect(pid)}

  defp serialize_metric_source(other), do: inspect(other)

  defp sources_match?(left, right), do: left == right

  defp entered_count(%{entered: entered}), do: :atomics.get(entered, 1)

  defp release_waiters(state) do
    broadcast_release(state)
  end

  defp broadcast_release(%{release_ref: release_ref, waiters: waiters}) do
    waiters
    |> :ets.lookup(:waiter)
    |> Enum.each(fn {:waiter, pid} -> send(pid, {:provider_wait_release, release_ref}) end)

    :ok
  rescue
    ArgumentError ->
      :ok
  end

  defp broadcast_release(%{release_ref: _release_ref}), do: :ok

  defp safe_ets_delete(table) do
    :ets.delete(table)
  rescue
    ArgumentError -> :ok
  end

  defp put_proof(proof) do
    case Application.get_env(:store, @env_key) do
      %{} = state ->
        Application.put_env(:store, @env_key, %{state | proof: proof, barrier: proof.barrier})

      _ ->
        :ok
    end
  end

  defp fetch_state! do
    case Application.get_env(:store, @env_key) do
      %{enabled: true} = state -> state
      _ -> raise "provider wait ownership probe is not configured"
    end
  end
end
