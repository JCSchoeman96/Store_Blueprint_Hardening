defmodule Store.TestSupport.ProviderWaitOwnershipProbe do
  @moduledoc false

  @env_key :provider_wait_ownership_probe
  @waiters_table :store_provider_wait_ownership_waiters
  @default_await_ms 30_000
  @default_release_wait_ms 60_000

  @type proof_status :: :proof_passed | :proof_failed | :proof_incomplete

  @type metric_sample :: %{
          sources: [map()],
          ready_conn_count: non_neg_integer(),
          checkout_queue_length: non_neg_integer(),
          metrics: [map()]
        }

  @type proof :: %{
          status: proof_status(),
          expected_probe_cohort: pos_integer(),
          entered_count: non_neg_integer(),
          barrier_reached_count: non_neg_integer(),
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
    release_wait_ms = Keyword.get(opts, :release_wait_ms, @default_release_wait_ms)
    after_admit = Keyword.get(opts, :after_admit)
    after_barrier_reached = Keyword.get(opts, :after_barrier_reached)

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
      release_wait_ms: release_wait_ms,
      after_admit: after_admit,
      after_barrier_reached: after_barrier_reached,
      release_ref: make_ref(),
      admitted: :atomics.new(1, []),
      barrier_reached: :atomics.new(1, []),
      released: :atomics.new(1, []),
      release_timeout: :atomics.new(1, []),
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
          evaluate_ownership_proof(fetch_state!())
      after
        state.await_ms ->
          incomplete_proof(
            fetch_state!(),
            "PROVIDER_WAIT_BARRIER_TIMEOUT expected=#{expected} " <>
              "admitted=#{admitted_count(state)} barrier_reached=#{barrier_reached_count(state)}"
          )
      end

    release_waiters(fetch_live_state(state))
    finalized = finalize_proof(result)
    put_proof(finalized)
    finalized
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

  @doc false
  @spec barrier_snapshot() :: map() | nil
  def barrier_snapshot do
    case Application.get_env(:store, @env_key) do
      %{enabled: true} = state ->
        %{
          expected_cohort: state.expected_cohort,
          admitted_count: admitted_count(state),
          barrier_reached_count: barrier_reached_count(state),
          waiter_count: waiter_count(state),
          released?: released?(state)
        }

      _ ->
        nil
    end
  end

  @spec expected_probe_cohort(pos_integer(), pos_integer()) :: pos_integer()
  def expected_probe_cohort(max_concurrency, users)
      when is_integer(max_concurrency) and max_concurrency >= 1 and is_integer(users) and
             users >= 1 do
    min(max_concurrency, users)
  end

  defp enter_barrier(state) do
    # ADMITTED — slot reservation only; does not prove barrier arrival.
    slot = :atomics.add_get(state.admitted, 1, 1)

    if slot > state.expected_cohort do
      :ok
    else
      maybe_run_after_admit(state, slot)
      run_barrier_waiter(state)
    end
  end

  defp maybe_run_after_admit(%{after_admit: fun}, slot) when is_function(fun, 1), do: fun.(slot)
  defp maybe_run_after_admit(_state, _slot), do: :ok

  defp run_barrier_waiter(state) do
    waiter = fn ->
      # WAITER_REGISTERED
      true = :ets.insert(state.waiters, {:waiter, self()})

      # LOCAL_OWNERSHIP_SAMPLED
      record_local_ownership(state)

      # BARRIER_REACHED — only now may the ready guard advance.
      reached = :atomics.add_get(state.barrier_reached, 1, 1)
      maybe_run_after_barrier_reached(state, reached)

      if reached == state.expected_cohort do
        send(state.sampler, {:provider_wait_cohort_ready, state.expected_cohort})
      end

      # WAITING_FOR_RELEASE (durable release checked before/while waiting)
      wait_for_release(state)
    end

    if state.hold_checkout? do
      Store.Repo.checkout(fn -> waiter.() end)
    else
      waiter.()
    end

    :ok
  end

  defp maybe_run_after_barrier_reached(%{after_barrier_reached: fun}, reached)
       when is_function(fun, 1) do
    fun.(reached)
  end

  defp maybe_run_after_barrier_reached(_state, _reached), do: :ok

  defp record_local_ownership(state) do
    if Store.Repo.checked_out?() do
      :atomics.add(state.local_checked_out, 1, 1)
    end

    :ok
  end

  defp wait_for_release(state) do
    release_ref = state.release_ref

    if released?(state) do
      :ok
    else
      receive do
        {:provider_wait_release, ^release_ref} ->
          :ok
      after
        state.release_wait_ms ->
          :atomics.put(state.release_timeout, 1, 1)

          raise RuntimeError,
            message:
              "PROVIDER_WAIT_BARRIER_RELEASE_TIMEOUT expected=#{state.expected_cohort} " <>
                "barrier_reached=#{barrier_reached_count(state)}"
      end
    end
  end

  defp evaluate_ownership_proof(state) do
    baseline = state.baseline || capture_baseline_locked!(state)

    case sample_pool_metrics() do
      {:ok, barrier} ->
        classify_barrier_sample(state, baseline, barrier)

      {:error, reason} ->
        incomplete_proof(
          state,
          "PROVIDER_WAIT_POOL_METRICS_UNAVAILABLE reason=#{inspect(reason)}"
        )
    end
  end

  defp classify_barrier_sample(state, baseline, barrier) do
    if sources_match?(baseline.sources, barrier.sources) do
      classify_matched_topology(state, baseline, barrier)
    else
      incomplete_proof(
        state,
        "PROVIDER_WAIT_POOL_TOPOLOGY_CHANGED baseline=#{inspect(baseline.sources)} barrier=#{inspect(barrier.sources)}"
      )
    end
  end

  defp classify_matched_topology(state, baseline, barrier) do
    occupancy_delta = baseline.ready_conn_count - barrier.ready_conn_count
    queue_delta = barrier.checkout_queue_length - baseline.checkout_queue_length
    local_checked_out = :atomics.get(state.local_checked_out, 1)
    reached = barrier_reached_count(state)

    cond do
      reached != state.expected_cohort ->
        incomplete_proof(
          state,
          "PROVIDER_WAIT_COHORT_MISMATCH expected=#{state.expected_cohort} " <>
            "barrier_reached=#{reached} admitted=#{admitted_count(state)}"
        )

      occupancy_delta != 0 or queue_delta != 0 or local_checked_out > 0 ->
        failed_ownership_proof(
          state,
          baseline,
          barrier,
          occupancy_delta,
          queue_delta,
          local_checked_out
        )

      true ->
        passed_ownership_proof(
          state,
          baseline,
          barrier,
          occupancy_delta,
          queue_delta,
          local_checked_out
        )
    end
  end

  defp failed_ownership_proof(
         state,
         baseline,
         barrier,
         occupancy_delta,
         queue_delta,
         local_checked_out
       ) do
    build_proof(
      state,
      :proof_failed,
      baseline,
      barrier,
      occupancy_delta,
      queue_delta,
      local_checked_out,
      [
        "STORE_REPO_OWNERSHIP_RETAINED_DURING_PROVIDER_WAIT",
        "occupancy_delta=#{occupancy_delta}",
        "queue_delta=#{queue_delta}",
        "process_local_checked_out_count=#{local_checked_out}"
      ]
    )
  end

  defp passed_ownership_proof(
         state,
         baseline,
         barrier,
         occupancy_delta,
         queue_delta,
         local_checked_out
       ) do
    build_proof(
      state,
      :proof_passed,
      baseline,
      barrier,
      occupancy_delta,
      queue_delta,
      local_checked_out,
      ["STORE_REPO_OWNERSHIP_RELEASED_DURING_PROVIDER_WAIT"]
    )
  end

  defp build_proof(
         state,
         status,
         baseline,
         barrier,
         occupancy_delta,
         queue_delta,
         local_checked_out,
         diagnostic_parts
       ) do
    %{
      status: status,
      expected_probe_cohort: state.expected_cohort,
      entered_count: admitted_count(state),
      barrier_reached_count: barrier_reached_count(state),
      baseline: baseline,
      barrier: barrier,
      occupancy_delta: occupancy_delta,
      queue_delta: queue_delta,
      process_local_checked_out_count: local_checked_out,
      hold_checkout?: state.hold_checkout?,
      diagnostic: Enum.join(diagnostic_parts, " ")
    }
  end

  defp incomplete_proof(state, diagnostic) do
    %{
      status: :proof_incomplete,
      expected_probe_cohort: state.expected_cohort,
      entered_count: admitted_count(state),
      barrier_reached_count: barrier_reached_count(state),
      baseline: state.baseline,
      barrier: nil,
      occupancy_delta: nil,
      queue_delta: nil,
      process_local_checked_out_count: :atomics.get(state.local_checked_out, 1),
      hold_checkout?: state.hold_checkout?,
      diagnostic: diagnostic
    }
  end

  defp finalize_proof(proof) do
    case Application.get_env(:store, @env_key) do
      %{release_timeout: release_timeout} = state ->
        if :atomics.get(release_timeout, 1) == 1 do
          %{
            proof
            | status: :proof_incomplete,
              diagnostic:
                "PROVIDER_WAIT_BARRIER_RELEASE_TIMEOUT expected=#{state.expected_cohort} " <>
                  "barrier_reached=#{barrier_reached_count(state)}"
          }
        else
          proof
        end

      _ ->
        proof
    end
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
        resolve_partition_pools(count, supervisor)

      other ->
        {:error, {:unexpected_repo_topology, pool_count, summarize_children(other)}}
    end
  end

  defp resolve_partition_pools(count, supervisor) do
    partition_pools =
      for {_id, pid, :worker, _} <- Supervisor.which_children(supervisor), is_pid(pid) do
        {:pool, pid}
      end

    if length(partition_pools) == count do
      {:ok, partition_pools}
    else
      {:error, {:partition_pool_count_mismatch, count, length(partition_pools)}}
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
            %{source: source, ready_conn_count: ready, checkout_queue_length: queue}

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

  defp admitted_count(%{admitted: admitted}), do: :atomics.get(admitted, 1)

  defp barrier_reached_count(%{barrier_reached: barrier_reached}),
    do: :atomics.get(barrier_reached, 1)

  defp waiter_count(%{waiters: waiters}) do
    waiters |> :ets.lookup(:waiter) |> length()
  rescue
    ArgumentError -> 0
  end

  defp released?(%{released: released}), do: :atomics.get(released, 1) == 1

  defp release_waiters(state), do: broadcast_release(state)

  defp broadcast_release(%{release_ref: release_ref, waiters: waiters, released: released}) do
    # Durable RELEASED state first, then notify currently registered waiters.
    :atomics.put(released, 1, 1)

    waiters
    |> :ets.lookup(:waiter)
    |> Enum.each(fn {:waiter, pid} -> send(pid, {:provider_wait_release, release_ref}) end)

    :ok
  rescue
    ArgumentError ->
      :ok
  end

  defp broadcast_release(%{released: released}) do
    :atomics.put(released, 1, 1)
    :ok
  end

  defp broadcast_release(_state), do: :ok

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

  defp fetch_live_state(fallback) do
    case Application.get_env(:store, @env_key) do
      %{} = state -> state
      _ -> fallback
    end
  end
end
