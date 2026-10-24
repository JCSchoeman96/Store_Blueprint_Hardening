defmodule Store.Subscriptions.SourceFenceContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, AccessEffectCurrentnessFence}
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures

  @start_timeout 30_000
  @transaction_timeout 30_000
  @task_timeout 10_000
  @blocking_timeout 8_000

  setup_all do
    assert_test_database!()

    pool_size = Repo.config()[:pool_size]

    unless is_integer(pool_size) and pool_size >= 3 do
      raise "real connection proof requires Store.Repo pool_size >= 3, got #{inspect(pool_size)}"
    end

    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)

    {:ok, %{effective_repo_pool_size: pool_size}}
  end

  test "same subscription blocks while an independent subscription proceeds", context do
    fixtures = create_committed_sources!()

    try do
      run_contention!(fixtures, context.effective_repo_pool_size)
    after
      cleanup_owned_sources!(fixtures)
    end
  end

  test "duplicate EFFECTIVE workers serialize and converge one exact grant" do
    fixtures = create_committed_sources!()
    fixture = fixtures.x
    parent = self()

    try do
      workers =
        for _ <- 1..2 do
          Task.async(fn ->
            Repo.checkout(fn ->
              send(parent, {:effective_worker_ready, self()})

              receive do
                :execute -> Facade.execute_effective_access_effect_for_system(fixture.effect.id)
              after
                @task_timeout -> {:error, :barrier_timeout}
              end
            end)
          end)
        end

      worker_pids =
        for _ <- 1..2 do
          assert_receive {:effective_worker_ready, pid}, @task_timeout
          pid
        end

      Enum.each(worker_pids, &send(&1, :execute))
      results = Enum.map(workers, &Task.await(&1, @transaction_timeout))

      assert Enum.count(results, &(&1 == {:ok, :applied})) == 1
      assert Enum.count(results, &(&1 == {:ok, :noop})) == 1
      assert_effective_grant!(fixture)
    after
      cleanup_owned_sources!(fixtures)
    end
  end

  test "a newer target producer and EFFECTIVE executor serialize in both lock-arrival orders" do
    producer_first = create_committed_sources!()

    try do
      run_producer_executor_race!(producer_first.x, :producer_first)
      assert fetch_effect_status!(producer_first.x.effect.id) == "superseded"
      assert latest_effect_disposition!(producer_first.x.subscription.id) == "non_effective"
      assert grants_for_source!(producer_first.x.subscription.id) == []
    after
      cleanup_owned_sources!(producer_first)
    end

    executor_first = create_committed_sources!()

    try do
      run_producer_executor_race!(executor_first.x, :executor_first)
      assert fetch_effect_status!(executor_first.x.effect.id) == "applied"
      assert latest_effect_disposition!(executor_first.x.subscription.id) == "non_effective"
      assert_effective_grant!(executor_first.x)
    after
      cleanup_owned_sources!(executor_first)
    end
  end

  test "ordinary legacy issue and F1 convergence contend safely in both arrival orders" do
    legacy_first = create_committed_sources!()

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(legacy_first.y) end)
      unrelated_before = grants_for_source!(legacy_first.y.subscription.id)
      run_legacy_executor_race!(legacy_first.x, :legacy_first)
      assert_effective_grant!(legacy_first.x)
      assert grants_for_source!(legacy_first.y.subscription.id) == unrelated_before
    after
      cleanup_owned_sources!(legacy_first)
    end

    executor_first = create_committed_sources!()

    try do
      assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(executor_first.y) end)
      unrelated_before = grants_for_source!(executor_first.y.subscription.id)
      run_legacy_executor_race!(executor_first.x, :executor_first)
      assert_effective_grant!(executor_first.x)
      assert grants_for_source!(executor_first.y.subscription.id) == unrelated_before
    after
      cleanup_owned_sources!(executor_first)
    end
  end

  defp run_contention!(%{x: source_x, y: source_y}, pool_size) do
    parent = self()
    run_ref = make_ref()

    task_a =
      start_waiting_task(run_ref, :start_a, fn ->
        run_source_task(parent, run_ref, :a_locked, source_x.effect.id, true)
      end)

    task_b =
      start_waiting_task(run_ref, :start_b, fn ->
        run_source_task(parent, run_ref, :b_started, source_x.effect.id, false)
      end)

    task_c =
      start_waiting_task(run_ref, :start_c, fn ->
        run_source_task(parent, run_ref, :c_started, source_y.effect.id, false)
      end)

    try do
      send(task_a.pid, {run_ref, :start_a})
      {a_pid, a_proof} = receive_event!(run_ref, :a_locked, @task_timeout)
      assert_current_proof!(a_proof, "task A")

      send(task_b.pid, {run_ref, :start_b})
      b_pid = receive_event!(run_ref, :b_started, @task_timeout)

      send(task_c.pid, {run_ref, :start_c})
      c_pid = receive_event!(run_ref, :c_started, @task_timeout)

      assert a_pid != b_pid
      assert a_pid != c_pid
      assert b_pid != c_pid

      c_result = await_task_result!(task_c, @task_timeout)
      assert {:ok, :current} = c_result

      blockers = await_blocking_pid!(b_pid, a_pid)

      send(task_a.pid, {run_ref, :release_a})

      a_result = await_task_result!(task_a, @task_timeout)
      b_result = await_task_result!(task_b, @task_timeout)
      assert {:ok, :current} = a_result
      assert {:ok, :current} = b_result

      IO.puts(
        "REAL_CONNECTIONS pool_size=#{pool_size} a_pid=#{a_pid} b_pid=#{b_pid} c_pid=#{c_pid} " <>
          "blockers=#{inspect(blockers)} c_current_before_a_release=true " <>
          "a_result=#{inspect(a_result)} b_result_after_release=#{inspect(b_result)}"
      )
    after
      send(task_a.pid, {run_ref, :release_a})
      send(task_b.pid, {run_ref, :cancel})
      send(task_c.pid, {run_ref, :cancel})
      stop_task_bounded(task_c)
      stop_task_bounded(task_b)
      stop_task_bounded(task_a)
    end
  end

  defp run_producer_executor_race!(fixture, :producer_first) do
    parent = self()
    run_ref = make_ref()

    producer =
      Task.async(fn ->
        Repo.transaction(fn ->
          producer_pid = backend_pid!()
          newer = establish_newer_non_effective_effect!(fixture)
          send(parent, {run_ref, :producer_locked, producer_pid, newer.id})
          wait_for_release!(run_ref)
        end)
      end)

    {producer_pid, newer_id} = receive_race_event!(run_ref, :producer_locked)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)
    await_blocking_pid!(executor_pid, producer_pid)
    send(producer.pid, {run_ref, :release})

    assert {:ok, _} = Task.await(producer, @task_timeout)
    assert {:ok, :noop} = Task.await(executor, @task_timeout)
    assert fetch_effect_status!(newer_id) == "required"
  end

  defp run_producer_executor_race!(fixture, :executor_first) do
    parent = self()
    run_ref = make_ref()

    assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
    {grant_barrier, barrier_pid, _grant_id} = start_source_grant_lock_barrier!(fixture, run_ref)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)

    executor_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        executor_pid,
        barrier_pid,
        :executor_at_source_convergence
      )

    producer =
      Task.async(fn ->
        Repo.transaction(fn ->
          producer_pid = backend_pid!()
          send(parent, {run_ref, :producer_started, producer_pid})
          effect = establish_newer_non_effective_effect!(fixture)
          effect
        end)
      end)

    producer_pid = receive_race_event!(run_ref, :producer_started)

    producer_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        producer_pid,
        executor_pid,
        :producer_waiting_for_executor
      )

    send(grant_barrier.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
    assert {:ok, %AccessEffect{status: :required}} = Task.await(producer, @task_timeout)

    IO.puts(
      "REAL_CONNECTIONS executor_first producer_vs_f1 executor_pid=#{executor_pid} " <>
        "grant_barrier_pid=#{barrier_pid} executor_blockers=#{inspect(executor_blockers)} " <>
        "producer_pid=#{producer_pid} producer_blockers=#{inspect(producer_blockers)} " <>
        "executor_committed_before_producer=true"
    )
  end

  defp run_legacy_executor_race!(fixture, :legacy_first) do
    parent = self()
    run_ref = make_ref()

    legacy =
      Task.async(fn ->
        Repo.transaction(fn ->
          legacy_pid = backend_pid!()
          :ok = issue_legacy_grant!(fixture)
          send(parent, {run_ref, :legacy_locked, legacy_pid})
          wait_for_release!(run_ref)
        end)
      end)

    legacy_pid = receive_race_event!(run_ref, :legacy_locked)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)
    await_blocking_pid!(executor_pid, legacy_pid)
    send(legacy.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(legacy, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
  end

  defp run_legacy_executor_race!(fixture, :executor_first) do
    parent = self()
    run_ref = make_ref()

    assert {:ok, :ok} = Repo.transaction(fn -> issue_legacy_grant!(fixture) end)
    {grant_barrier, barrier_pid, grant_id} = start_source_grant_lock_barrier!(fixture, run_ref)

    executor =
      Task.async(fn ->
        Repo.checkout(fn ->
          executor_pid = backend_pid!()
          send(parent, {run_ref, :executor_started, executor_pid})
          Facade.execute_effective_access_effect_for_system(fixture.effect.id)
        end)
      end)

    executor_pid = receive_race_event!(run_ref, :executor_started)

    executor_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        executor_pid,
        barrier_pid,
        :executor_at_source_convergence
      )

    legacy =
      Task.async(fn ->
        Repo.transaction(fn ->
          legacy_pid = backend_pid!()
          send(parent, {run_ref, :legacy_started, legacy_pid})
          issue_legacy_grant!(fixture)
        end)
      end)

    legacy_pid = receive_race_event!(run_ref, :legacy_started)

    legacy_blockers =
      assert_blocked_by_barrier!(
        grant_barrier,
        run_ref,
        legacy_pid,
        executor_pid,
        :legacy_waiting_behind_f1
      )

    send(grant_barrier.pid, {run_ref, :release})

    assert {:ok, :released} = Task.await(grant_barrier, @task_timeout)
    assert {:ok, :applied} = Task.await(executor, @task_timeout)
    assert {:ok, :ok} = Task.await(legacy, @task_timeout)

    IO.puts(
      "REAL_CONNECTIONS executor_first legacy_vs_f1 executor_pid=#{executor_pid} " <>
        "grant_id=#{Ecto.UUID.cast!(grant_id)} grant_barrier_pid=#{barrier_pid} " <>
        "executor_blockers=#{inspect(executor_blockers)} legacy_pid=#{legacy_pid} " <>
        "legacy_blockers=#{inspect(legacy_blockers)} f1_committed_before_legacy=true"
    )
  end

  defp start_source_grant_lock_barrier!(fixture, run_ref) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            barrier_pid = backend_pid!()

            %{rows: [[grant_id]]} =
              Repo.query!(
                """
                SELECT id
                FROM entitlement_grants
                WHERE source_kind = 'subscription' AND source_id = $1
                ORDER BY id
                LIMIT 1
                FOR UPDATE
                """,
                [Ecto.UUID.dump!(fixture.subscription.id)]
              )

            send(parent, {run_ref, :grant_barrier_locked, barrier_pid, grant_id})
            await_barrier_observation!(run_ref)
          end,
          timeout: @transaction_timeout
        )
      end)

    {barrier_pid, grant_id} = receive_race_event!(run_ref, :grant_barrier_locked)
    {task, barrier_pid, grant_id}
  end

  defp assert_blocked_by_barrier!(barrier, run_ref, blocked_pid, expected_blocker_pid, label) do
    send(
      barrier.pid,
      {run_ref, :assert_blocked, blocked_pid, expected_blocker_pid, self(), label}
    )

    blockers = receive_race_event!(run_ref, {:blocking_observed, label})
    assert expected_blocker_pid in blockers
    blockers
  end

  defp await_barrier_observation!(run_ref) do
    receive do
      {^run_ref, :assert_blocked, blocked_pid, expected_blocker_pid, observer, label} ->
        blockers = await_blocking_pid!(blocked_pid, expected_blocker_pid)
        send(observer, {run_ref, {:blocking_observed, label}, blockers})
        await_barrier_observation!(run_ref)

      {^run_ref, :release} ->
        :released
    after
      @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
    end
  end

  defp establish_newer_non_effective_effect!(fixture) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: source_version,
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    {:ok, input} = EstablishAccessEffectInput.new(attrs)
    {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp issue_legacy_grant!(fixture) do
    subscription = %{
      id: fixture.subscription.id,
      user_id: fixture.subscription.user_id,
      current_period_end_at: fixture.subscription.current_period_end_at
    }

    plan = %{
      entitlement_kind: fixture.revision.entitlement_kind,
      entitlement_scope_key: fixture.revision.entitlement_scope_key
    }

    case EntitlementsFacade.issue_subscription_source_grant_strict_for_system(subscription, plan) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp assert_effective_grant!(fixture) do
    assert [%EntitlementGrant{} = grant] = grants_for_source!(fixture.subscription.id)
    assert grant.status == :active
    assert grant.kind == fixture.effect.entitlement_kind
    assert grant.scope_key == fixture.effect.entitlement_scope_key
    assert grant.valid_from_at == fixture.effect.valid_from_at
    assert grant.valid_to_at == fixture.effect.valid_until_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_effect_status!(effect_id) do
    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status::text FROM access_effects WHERE id = $1", [
        Ecto.UUID.dump!(effect_id)
      ])

    status
  end

  defp latest_effect_disposition!(subscription_id) do
    {:ok, %{rows: [[disposition]]}} =
      Repo.query(
        "SELECT disposition::text FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC LIMIT 1",
        [Ecto.UUID.dump!(subscription_id)]
      )

    disposition
  end

  defp receive_race_event!(run_ref, event) do
    receive do
      {^run_ref, ^event, value} -> value
      {^run_ref, ^event, pid, value} -> {pid, value}
    after
      @task_timeout -> flunk("timed out waiting for #{event}")
    end
  end

  defp wait_for_release!(run_ref) do
    receive do
      {^run_ref, :release} -> :released
    after
      @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
    end
  end

  defp start_waiting_task(run_ref, start_tag, task_fun) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          receive do
            {^run_ref, ^start_tag} -> task_fun.()
            {^run_ref, :cancel} -> :cancelled
          after
            @start_timeout -> {:error, :start_timeout}
          end

        send(parent, {run_ref, :task_result, self(), result})
      end)

    %{pid: pid, monitor_ref: monitor_ref, run_ref: run_ref}
  end

  defp run_source_task(parent, run_ref, event, access_effect_id, hold_lock?) do
    Repo.transaction(
      fn ->
        backend_pid = backend_pid!()
        if event != :a_locked, do: send(parent, {run_ref, event, backend_pid})

        proof = AccessEffectCurrentnessFence.prove(access_effect_id)

        if event == :a_locked do
          send(parent, {run_ref, event, backend_pid, proof})
        end

        assert_current_proof!(proof, "#{event}")

        if hold_lock? do
          receive do
            {^run_ref, :release_a} -> :current
            {^run_ref, :cancel} -> Repo.rollback(:cancelled)
          after
            @transaction_timeout -> Repo.rollback(:source_lock_release_timeout)
          end
        else
          :current
        end
      end,
      timeout: @transaction_timeout
    )
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp receive_event!(run_ref, event, timeout) do
    receive do
      {^run_ref, ^event, value} -> value
      {^run_ref, ^event, pid, proof} -> {pid, proof}
    after
      timeout -> flunk("timed out waiting for #{event}")
    end
  end

  defp await_blocking_pid!(blocked_pid, expected_blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @blocking_timeout
    poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, [])
  end

  defp poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, last_blockers) do
    %{rows: [[blockers]]} =
      Repo.query!("SELECT pg_blocking_pids($1)", [blocked_pid], timeout: 1_000)

    cond do
      expected_blocker_pid in blockers ->
        blockers

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "PostgreSQL did not report backend #{expected_blocker_pid} blocking " <>
            "backend #{blocked_pid}; last pg_blocking_pids result was #{inspect(last_blockers)}"
        )

      true ->
        Process.sleep(25)
        poll_blocking_pids!(blocked_pid, expected_blocker_pid, deadline, blockers)
    end
  end

  defp assert_current_proof!({:ok, %{status: :current}}, _label), do: :ok

  defp assert_current_proof!(proof, label) do
    raise "expected #{label} to prove a current AccessEffect, got #{inspect(proof)}"
  end

  defp await_task_result!(task, timeout) do
    receive do
      {run_ref, :task_result, pid, result}
      when run_ref == task.run_ref and pid == task.pid ->
        Process.demonitor(task.monitor_ref, [:flush])
        result

      {:DOWN, monitor_ref, :process, pid, reason}
      when monitor_ref == task.monitor_ref and pid == task.pid ->
        flunk("contention task exited before returning its result: #{inspect(reason)}")
    after
      timeout ->
        flunk("timed out waiting for contention task #{inspect(task.pid)}")
    end
  end

  defp stop_task_bounded(task) do
    if Process.alive?(task.pid) do
      receive do
        {run_ref, :task_result, pid, _result}
        when run_ref == task.run_ref and pid == task.pid ->
          await_task_exit_bounded(task)

        {:DOWN, monitor_ref, :process, pid, _reason}
        when monitor_ref == task.monitor_ref and pid == task.pid ->
          :ok
      after
        1_000 ->
          Process.exit(task.pid, :kill)
          await_task_exit_bounded(task)
      end
    else
      Process.demonitor(task.monitor_ref, [:flush])
      :ok
    end
  end

  defp await_task_exit_bounded(task) do
    receive do
      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == task.monitor_ref and pid == task.pid ->
        :ok
    after
      1_000 ->
        Process.exit(task.pid, :kill)

        receive do
          {:DOWN, monitor_ref, :process, pid, _reason}
          when monitor_ref == task.monitor_ref and pid == task.pid ->
            :ok
        after
          1_000 -> raise "contention task did not stop after bounded cleanup"
        end
    end
  end

  defp create_committed_sources! do
    assert_test_database!()

    case Repo.transaction(
           fn ->
             %{x: create_source_fixture!("x"), y: create_source_fixture!("y")}
           end,
           timeout: @transaction_timeout
         ) do
      {:ok, fixtures} ->
        fixtures

      {:error, reason} ->
        raise "unable to create committed contention sources: #{inspect(reason)}"
    end
  end

  defp create_source_fixture!(label) do
    unique = Ecto.UUID.generate()
    customer = SubscriptionsFixtures.create_customer!("f0_fence_#{label}_#{unique}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f0-source-fence-#{label}-#{unique}"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        create_payment_intent?: false
      })

    effect_input =
      input!(%{
        subscription_id: fixture.subscription.id,
        source_version: fixture.subscription.aggregate_version,
        disposition: :effective,
        entitlement_kind: fixture.revision.entitlement_kind,
        entitlement_scope_key: fixture.revision.entitlement_scope_key,
        valid_from_at: fixture.subscription.current_period_start_at,
        valid_until_at: fixture.subscription.current_period_end_at,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: fixture.subscription.current_contract_change_id,
        plan_revision_id: fixture.revision.id
      })

    {:ok, effect} = Facade.establish_access_effect_for_system(effect_input)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      variant_plan: variant_plan,
      plan: plan,
      effect: effect
    })
  end

  defp input!(attrs) do
    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, error} -> raise "invalid contention AccessEffect input: #{inspect(error)}"
    end
  end

  defp cleanup_owned_sources!(fixtures) do
    assert_test_database!()

    case Repo.transaction(
           fn ->
             cleanup_owned_source!(fixtures.y)
             cleanup_owned_source!(fixtures.x)
           end,
           timeout: @transaction_timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "unable to clean owned contention fixtures: #{inspect(reason)}"
    end
  end

  defp cleanup_owned_source!(fixture) do
    subscription_id = uuid_param!(fixture.subscription.id)
    item_id = uuid_param!(fixture.item.id)
    line_item_id = uuid_param!(fixture.line_item.id)
    order_id = uuid_param!(fixture.order.id)
    variant_plan_id = uuid_param!(fixture.variant_plan.id)
    revision_id = uuid_param!(fixture.revision.id)
    plan_id = uuid_param!(fixture.plan.id)
    product_id = uuid_param!(fixture.product.id)
    user_id = uuid_param!(fixture.customer.id)

    Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])
    Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])
    Repo.query!("DELETE FROM subscription_items WHERE id = $1", [item_id])
    Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
    Repo.query!("DELETE FROM email_outboxes WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
    Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
    Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
    Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [variant_plan_id])
    Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [revision_id])
    Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
    Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
    Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

    :ok
  end

  defp uuid_param!(uuid), do: Ecto.UUID.dump!(uuid)

  defp assert_test_database! do
    expected_database =
      System.get_env("STORE_TEST_DATABASE_NAME", "store_blueprint_test") <>
        (System.get_env("STORE_TEST_DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") || "")

    actual_database = Repo.config()[:database]

    unless Mix.env() == :test and actual_database == expected_database do
      raise "contention test database guard failed: MIX_ENV=#{inspect(Mix.env())}, " <>
              "configured_database=#{inspect(actual_database)}, expected_database=#{inspect(expected_database)}"
    end

    :ok
  end
end
