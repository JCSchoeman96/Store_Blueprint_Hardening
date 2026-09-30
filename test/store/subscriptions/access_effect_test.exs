defmodule Store.Subscriptions.AccessEffectTest do
  use Store.DataCase, async: false

  import Ash.Expr

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "exact replay reuses one durable AccessEffect identity" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    assert {:ok, first} = establish(input)
    assert {:ok, replay} = establish(input)

    assert replay.id == first.id
    assert replay.status == :required
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "a caller-owned outer rollback removes a newly established AccessEffect" do
    fixture = create_committed_subscription_fixture!()
    input = access_effect_input(fixture)

    result =
      Sandbox.unboxed_run(Store.Repo, fn ->
        Store.Repo.transaction(fn ->
          assert {:ok, effect} = establish(input)
          Store.Repo.rollback({:access_effect_rollback, effect.id})
        end)
      end)

    assert {:error, {:access_effect_rollback, _effect_id}} = result
    assert count_access_effects(fixture.subscription.id) == 0
  end

  test "concurrent exact replay creates one row and returns the same identity" do
    fixture = create_committed_subscription_fixture!()
    input = access_effect_input(fixture)
    parent = self()

    lock_holder = start_subscription_lock_holder(fixture.subscription.id, parent)
    assert_receive {:subscription_locked, blocker_pid}

    first_writer = start_writer(input, :first, parent)
    assert_receive {:access_effect_writer_started, :first}
    await_blocked_writers!(blocker_pid, 1)

    second_writer = start_writer(input, :second, parent)
    assert_receive {:access_effect_writer_started, :second}
    await_blocked_writers!(blocker_pid, 2)

    send(lock_holder.pid, :release)
    assert {:ok, :released} = Task.await(lock_holder, 10_000)

    assert {:ok, first} = Task.await(first_writer, 10_000)
    assert {:ok, second} = Task.await(second_writer, 10_000)
    assert second.id == first.id
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "same-version target conflict fails closed without changing stored evidence" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    conflicting_input = access_effect_input(fixture, %{disposition: :non_effective})

    assert {:ok, first} = establish(input)
    assert {:error, %Error{code: "IDEMPOTENCY_KEY_REUSE_MISMATCH"}} = establish(conflicting_input)

    assert {:ok, current} = current_access_effect(fixture.subscription)
    assert current.id == first.id
    assert current.disposition == :effective
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "exact historical replay reuses evidence after current Subscription provenance moves" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    assert {:ok, effect} = establish(input)

    Store.Repo.query!(
      "UPDATE subscriptions SET current_plan_revision_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert {:ok, replay} = establish(input)
    assert replay.id == effect.id
  end

  test "target fingerprint covers every canonical target field, including nil values" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    fingerprint = target_fingerprint(input)

    variations = [
      %{subscription_id: Ecto.UUID.generate()},
      %{source_version: input.source_version + 1},
      %{disposition: :non_effective},
      %{entitlement_kind: :digital_library},
      %{entitlement_scope_key: "vip_members"},
      %{valid_until_at: DateTime.add(input.valid_until_at, 1, :day)},
      %{valid_until_at: nil},
      %{entitlement_kind: nil, entitlement_scope_key: nil},
      %{source_order_line_item_id: Ecto.UUID.generate()},
      %{contract_change_id: Ecto.UUID.generate()},
      %{plan_revision_id: Ecto.UUID.generate()}
    ]

    assert target_fingerprint(input) == fingerprint

    Enum.each(variations, fn changed_fields ->
      changed_input = access_effect_input(fixture, changed_fields)
      refute target_fingerprint(changed_input) == fingerprint
    end)
  end

  test "source-version gaps are valid and unrelated aggregate writes do not stale the latest target" do
    fixture = create_subscription_fixture!()
    first_input = access_effect_input(fixture, %{source_version: 8})
    later_input = access_effect_input(fixture, %{source_version: 13})

    assert {:ok, first} = establish(first_input)
    assert {:ok, later} = establish(later_input)
    assert later.source_version == 13

    Store.Repo.query!(
      "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert {:ok, current} = current_access_effect(fixture.subscription)
    assert current.id == later.id
    refute current.source_version == fixture.subscription.aggregate_version + 1
    assert fetch_access_effect!(first.id).status == :superseded
  end

  test "an older target cannot become current after a newer target exists" do
    fixture = create_subscription_fixture!()
    newer_input = access_effect_input(fixture, %{source_version: 12})
    older_input = access_effect_input(fixture, %{source_version: 9})

    assert {:ok, newer} = establish(newer_input)
    assert {:error, %Error{code: "STALE_RECORD"}} = establish(older_input)

    assert {:ok, current} = current_access_effect(fixture.subscription)
    assert current.id == newer.id
    assert count_access_effects(fixture.subscription.id) == 1
  end

  test "competing source versions preserve the newer target for either lock-arrival order" do
    Enum.each([[4, 9], [9, 4]], fn [first_version, second_version] ->
      fixture = create_committed_subscription_fixture!()
      first_input = access_effect_input(fixture, %{source_version: first_version})
      second_input = access_effect_input(fixture, %{source_version: second_version})
      parent = self()

      lock_holder = start_subscription_lock_holder(fixture.subscription.id, parent)
      assert_receive {:subscription_locked, blocker_pid}

      first_writer = start_writer(first_input, :first, parent)
      assert_receive {:access_effect_writer_started, :first}
      await_blocked_writers!(blocker_pid, 1)

      second_writer = start_writer(second_input, :second, parent)
      assert_receive {:access_effect_writer_started, :second}
      await_blocked_writers!(blocker_pid, 2)

      send(lock_holder.pid, :release)
      assert {:ok, :released} = Task.await(lock_holder, 10_000)

      first_result = Task.await(first_writer, 10_000)
      second_result = Task.await(second_writer, 10_000)
      high_version = max(first_version, second_version)

      assert {:ok, current} = current_access_effect(fixture.subscription)
      assert current.source_version == high_version

      if first_version < second_version do
        assert {:ok, first} = first_result
        assert {:ok, second} = second_result
        assert fetch_access_effect!(first.id).status == :superseded
        assert second.status == :required
        assert count_access_effects(fixture.subscription.id) == 2
      else
        assert {:ok, first} = first_result
        assert {:error, %Error{code: "STALE_RECORD"}} = second_result
        assert first.source_version == high_version
        assert count_access_effects(fixture.subscription.id) == 1
      end
    end)
  end

  test "REQUIRED supersession follows REQUIRED to PENDING to SUPERSEDED in one transaction" do
    assert_supersession_path(:required, 2)
  end

  test "PENDING supersession follows the direct PENDING to SUPERSEDED edge" do
    assert_supersession_path(:pending, 1)
  end

  test "FAILED_RETRYABLE supersession follows FAILED_RETRYABLE to PENDING to SUPERSEDED in one transaction" do
    assert_supersession_path(:failed_retryable, 2)
  end

  test "APPLIED and SUPERSEDED effects remain terminal and cannot reopen" do
    fixture = create_subscription_fixture!()
    applied = establish!(access_effect_input(fixture, %{source_version: 2}))
    pending = transition!(:mark_access_effect_pending_for_system, applied)
    applied = transition!(:mark_access_effect_applied_for_system, pending)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_pending_for_system, applied)

    newer = establish!(access_effect_input(fixture, %{source_version: 5}))
    pending = transition!(:mark_access_effect_pending_for_system, newer)
    superseded = transition!(:supersede_access_effect_for_system, pending)

    assert superseded.status == :superseded

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:mark_access_effect_pending_for_system, superseded)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             transition(:retry_access_effect_for_system, superseded)

    assert fetch_access_effect!(applied.id).status == :applied
    assert fetch_access_effect!(superseded.id).status == :superseded
  end

  test "lifecycle actions cannot mutate target evidence" do
    fixture = create_subscription_fixture!()
    required = establish!(access_effect_input(fixture))

    result =
      required
      |> Ash.Changeset.for_update(
        :mark_pending_from_required,
        %{disposition: :non_effective},
        context: %{system?: true}
      )
      |> Ash.update(
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    assert {:error, _reason} = result
    persisted = fetch_access_effect!(required.id)
    assert persisted.status == :required
    assert persisted.disposition == :effective
  end

  test "AccessEffect creation has bounded create, replay, and current-target query counts" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)

    {create_result, create_queries} = capture_repo_queries(fn -> establish(input) end)
    assert {:ok, effect} = create_result

    {replay_result, replay_queries} = capture_repo_queries(fn -> establish(input) end)
    assert {:ok, replayed} = replay_result
    assert replayed.id == effect.id

    {current_result, current_queries} =
      capture_repo_queries(fn -> current_access_effect(fixture.subscription) end)

    assert {:ok, current} = current_result
    assert current.id == effect.id
    assert length(data_queries(create_queries)) == 4
    assert length(data_queries(replay_queries)) == 2
    assert length(data_queries(current_queries)) == 1

    current_sql =
      Enum.find(current_queries, &String.contains?(String.downcase(&1), "access_effects"))

    assert String.contains?(String.downcase(current_sql), "order by")
    assert String.contains?(String.downcase(current_sql), "source_version")
    assert String.contains?(String.downcase(current_sql), "desc")
    assert String.contains?(String.downcase(current_sql), "limit")

    Store.Repo.query!("SET LOCAL enable_seqscan = off")

    {:ok, %{rows: plan_rows}} =
      Store.Repo.query(
        "EXPLAIN SELECT id FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC LIMIT 1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )

    explain = plan_rows |> List.flatten() |> Enum.join(" ")
    assert explain =~ "access_effects_subscription_source_version_index"
    assert explain =~ "Limit"
  end

  test "create and replay perform no Entitlements, worker, or provider side effect" do
    fixture = create_subscription_fixture!()
    input = access_effect_input(fixture)
    StripeAPIStub.stub_unexpected!("AccessEffect must not call a payment provider")

    entitlement_count_before = count_subscription_entitlement_grants(fixture.subscription.id)
    job_count_before = count_oban_jobs()

    assert {:ok, _effect} = establish(input)
    assert {:ok, _replay} = establish(input)

    assert count_subscription_entitlement_grants(fixture.subscription.id) ==
             entitlement_count_before

    assert count_oban_jobs() == job_count_before
  end

  defp create_subscription_fixture! do
    customer =
      SubscriptionsFixtures.create_customer!("sbh_50_06_access_effect_#{Ecto.UUID.generate()}")

    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "members"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      plan: plan,
      variant_plan: variant_plan
    })
  end

  defp create_committed_subscription_fixture! do
    fixture = Sandbox.unboxed_run(Store.Repo, fn -> create_subscription_fixture!() end)

    on_exit(fn -> cleanup_committed_subscription_fixture!(fixture) end)
    fixture
  end

  defp cleanup_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)

      Store.Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

      Store.Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [
        subscription_id
      ])

      Store.Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Store.Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Store.Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Store.Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])

      Store.Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [
        variant_id
      ])

      Store.Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Store.Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Store.Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Store.Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp access_effect_input(fixture, overrides \\ %{}) do
    subscription = fixture.subscription
    revision = fixture.revision

    attrs =
      %{
        subscription_id: subscription.id,
        source_version: subscription.aggregate_version,
        disposition: :effective,
        entitlement_kind: revision.entitlement_kind,
        entitlement_scope_key: revision.entitlement_scope_key,
        valid_until_at: subscription.current_period_end_at,
        source_order_line_item_id: fixture.line_item.id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: revision.id
      }
      |> Map.merge(overrides)

    case EstablishAccessEffectInput.new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise "invalid AccessEffect test input: #{inspect(reason)}"
    end
  end

  defp establish(input) do
    Facade.establish_access_effect_for_system(input)
  end

  defp establish!(input) do
    assert {:ok, effect} = establish(input)
    effect
  end

  defp current_access_effect(subscription) do
    Facade.get_current_access_effect_for_system(subscription)
  end

  defp transition(name, effect), do: apply(Facade, name, [effect])

  defp transition!(name, effect) do
    assert {:ok, transitioned} = transition(name, effect)
    transitioned
  end

  defp target_fingerprint(input) do
    AccessEffect.target_fingerprint(input)
  end

  defp fetch_access_effect!(id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
    |> List.first()
  end

  defp assert_supersession_path(initial_status, expected_update_count) do
    fixture = create_subscription_fixture!()
    initial_input = access_effect_input(fixture, %{source_version: 3})
    required = establish!(initial_input)

    current =
      case initial_status do
        :required ->
          required

        :pending ->
          transition!(:mark_access_effect_pending_for_system, required)

        :failed_retryable ->
          required
          |> then(&transition!(:mark_access_effect_pending_for_system, &1))
          |> then(&transition!(:mark_access_effect_failed_retryable_for_system, &1))
      end

    newer_input = access_effect_input(fixture, %{source_version: 11})
    {newer_result, queries} = capture_repo_queries(fn -> establish(newer_input) end)
    assert {:ok, newer} = newer_result

    updates =
      Enum.count(queries, fn query ->
        sql = String.downcase(String.trim(query))
        String.starts_with?(sql, "update") and String.contains?(sql, "access_effects")
      end)

    assert updates == expected_update_count
    assert fetch_access_effect!(current.id).status == :superseded
    assert newer.status == :required
    assert count_access_effects(fixture.subscription.id) == 2
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :access_effect_query_count, make_ref()}
    message_ref = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, {pid, ref} ->
          send(pid, {ref, metadata.query})
        end,
        {self(), message_ref}
      )

    try do
      result = fun.()
      {result, receive_repo_queries(message_ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp receive_repo_queries(ref, queries) do
    receive do
      {^ref, query} -> receive_repo_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp data_queries(queries) do
    Enum.reject(queries, fn query ->
      String.downcase(String.trim(query)) in ["begin", "commit", "rollback"]
    end)
  end

  defp count_subscription_entitlement_grants(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        "SELECT count(*) FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
  end

  defp count_oban_jobs do
    {:ok, %{rows: [[count]]}} = Store.Repo.query("SELECT count(*) FROM oban_jobs")
    count
  end

  defp start_subscription_lock_holder(subscription_id, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        hold_subscription_lock(subscription_id, parent)
      end)
    end)
  end

  defp hold_subscription_lock(subscription_id, parent) do
    Store.Repo.transaction(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")

      Store.Repo.query!(
        "SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE",
        [Ecto.UUID.dump!(subscription_id)]
      )

      send(parent, {:subscription_locked, backend_pid})
      await_subscription_lock_release()
    end)
  end

  defp await_subscription_lock_release do
    receive do
      :release -> :released
    after
      10_000 -> Store.Repo.rollback(:subscription_lock_holder_timeout)
    end
  end

  defp start_writer(input, writer, parent) do
    Task.async(fn ->
      Sandbox.unboxed_run(Store.Repo, fn ->
        send(parent, {:access_effect_writer_started, writer})
        establish(input)
      end)
    end)
  end

  defp await_blocked_writers!(blocker_pid, expected, attempts_left \\ 500)

  defp await_blocked_writers!(blocker_pid, expected, attempts_left)
       when attempts_left > 0 do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query(
        """
        SELECT count(*)
        FROM pg_stat_activity waiting
        WHERE waiting.wait_event_type = 'Lock'
          AND (
            $1 = ANY(pg_blocking_pids(waiting.pid))
            OR EXISTS (
              SELECT 1
              FROM pg_stat_activity direct_waiter
              WHERE $1 = ANY(pg_blocking_pids(direct_waiter.pid))
                AND direct_waiter.pid = ANY(pg_blocking_pids(waiting.pid))
            )
          )
        """,
        [blocker_pid]
      )

    if count >= expected do
      :ok
    else
      Process.sleep(10)
      await_blocked_writers!(blocker_pid, expected, attempts_left - 1)
    end
  end

  defp await_blocked_writers!(_blocker_pid, expected, _attempts_left) do
    flunk("expected #{expected} AccessEffect writers to wait for the Subscription row lock")
  end

  defp count_access_effects(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Store.Repo.query("SELECT count(*) FROM access_effects WHERE subscription_id = $1", [
        Ecto.UUID.dump!(subscription_id)
      ])

    count
  end
end
