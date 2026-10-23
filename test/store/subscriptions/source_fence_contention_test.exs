defmodule Store.Subscriptions.SourceFenceContentionTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections
  @tag timeout: 60_000

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.AccessEffectCurrentnessFence
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
    effect_id = uuid_param!(fixture.effect.id)
    subscription_id = uuid_param!(fixture.subscription.id)
    item_id = uuid_param!(fixture.item.id)
    line_item_id = uuid_param!(fixture.line_item.id)
    order_id = uuid_param!(fixture.order.id)
    variant_plan_id = uuid_param!(fixture.variant_plan.id)
    revision_id = uuid_param!(fixture.revision.id)
    plan_id = uuid_param!(fixture.plan.id)
    product_id = uuid_param!(fixture.product.id)
    user_id = uuid_param!(fixture.customer.id)

    Repo.query!("DELETE FROM access_effects WHERE id = $1", [effect_id])
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
