defmodule Store.Subscriptions.Sbh1005ChargedContractReconciliationTest do
  use Store.DataCase, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation

  alias Store.Subscriptions.{
    ContractChange,
    Facade,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "a successful bound renewal applies the exact charged contract" do
    fixture = charged_bound_renewal!("sbh_10_05_exact", quantity: 3)

    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      revision: revision,
      contract_change: contract_change,
      collection: collection
    } = fixture

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    assert handoff.order_id == order.id
    assert handoff.renewal_attempt_id == attempt.id
    assert handoff.collection_attempt_id == collection.id

    before = fetch_subscription!(subscription.id)
    assert attempt.plan_revision_id == revision.id
    assert attempt.quantity == 3
    assert attempt.amount_minor == contract_change.target_amount_minor
    assert attempt.currency == contract_change.target_currency
    assert contract_change.status == :bound_to_renewal

    decoy_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 5,
        amount_minor: 2_700,
        currency: "GBP"
      })

    %{variant: decoy_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    # Mutable current projections must not replace the contract charged by this
    # occurrence. Future-target projections remain empty here.
    Store.Repo.query!(
      "UPDATE subscriptions SET subscription_plan_id = $1, variant_id = $2, renewal_amount_minor = 17, renewal_currency = 'CAD', quantity = 9 WHERE id = $3",
      [
        Ecto.UUID.dump!(decoy_plan.id),
        Ecto.UUID.dump!(decoy_variant.id),
        Ecto.UUID.dump!(subscription.id)
      ]
    )

    Store.Repo.query!(
      "UPDATE subscription_plans SET entitlement_kind = 'membership_access', entitlement_scope_key = 'platinum' WHERE id = $1",
      [Ecto.UUID.dump!(revision.subscription_plan_id)]
    )

    {result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 first charged application query_count=#{stats.query_count}")
    assert stats.query_count > 0
    assert {:ok, :reconciled} = result

    applied = fetch_subscription!(subscription.id)
    assert applied.current_plan_revision_id == revision.id
    assert applied.subscription_plan_id == revision.subscription_plan_id
    assert applied.variant_id == attempt.variant_id
    assert applied.quantity == attempt.quantity
    assert applied.renewal_amount_minor == attempt.amount_minor
    assert applied.renewal_currency == attempt.currency
    assert applied.current_period_start_at == attempt.period_start_at
    assert applied.current_period_end_at == attempt.period_end_at
    assert applied.membership_key == revision.entitlement_scope_key

    assert [%EntitlementGrant{kind: :membership_access, scope_key: "gold", status: :active}] =
             active_grants_for(subscription.id)

    assert applied.aggregate_version == before.aggregate_version + 1
    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded
  end

  test "an exact charged replay leaves the applied subscription version unchanged" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_replay", quantity: 2)

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    # Current main rejects this bound attempt. After the reconciliation path is
    # implemented, replay must keep the same aggregate version and target.
    {first_result, first_stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 first charged application query_count=#{first_stats.query_count}")
    assert first_stats.query_count > 0
    assert {:ok, :reconciled} = first_result

    version = fetch_subscription!(subscription.id).aggregate_version

    {replay_result, replay_stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-230 exact charged replay query_count=#{replay_stats.query_count}")
    assert replay_stats.query_count > 0
    assert {:ok, :noop} = replay_result

    assert fetch_subscription!(subscription.id).aggregate_version == version
    assert fetch_attempt!(attempt.id).status == :succeeded
  end

  test "paid renewal reconciliation rejects a wrong collection or supplied PaymentIntent ID" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_wrong_handoff_ids")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    before = fetch_subscription!(subscription.id)

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               Keyword.put(handoff_opts(handoff), :collection_attempt_id, Ecto.UUID.generate())
             )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               Keyword.put(handoff_opts(handoff), :payment_intent_id, Ecto.UUID.generate())
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before.aggregate_version
    assert after_subscription.current_period_start_at == before.current_period_start_at
    assert after_subscription.current_period_end_at == before.current_period_end_at
    assert after_subscription.current_plan_revision_id == before.current_plan_revision_id
    assert fetch_contract_change!(attempt.contract_change_id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "the exact collection PaymentIntent overrides a stale RenewalAttempt pointer" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      charged_bound_renewal!("sbh_10_05_stale_attempt_pointer")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    stale_intent = create_other_payment_intent!(subscription, order)

    Store.Repo.query!(
      "UPDATE renewal_attempts SET payment_intent_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(stale_intent.id), Ecto.UUID.dump!(attempt.id)]
    )

    assert fetch_attempt!(attempt.id).payment_intent_id == stale_intent.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    assert fetch_attempt!(attempt.id).payment_intent_id == handoff.payment_intent_id
  end

  test "a PaymentApplication for another PaymentIntent fails before commercial mutation" do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      contract_change: contract_change,
      collection: collection
    } = charged_bound_renewal!("sbh_10_05_mismatched_application")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    other_intent = create_other_payment_intent!(subscription, order)
    before = fetch_subscription!(subscription.id)

    Store.Repo.query!(
      "UPDATE payment_applications SET payment_intent_id = $1 WHERE order_id = $2",
      [Ecto.UUID.dump!(other_intent.id), Ecto.UUID.dump!(order.id)]
    )

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before.aggregate_version
    assert after_subscription.current_period_start_at == before.current_period_start_at
    assert after_subscription.current_period_end_at == before.current_period_end_at
    assert fetch_contract_change!(contract_change.id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "unchanged paid renewal reconciles with an exact revision and records query count" do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_05_unchanged")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_900,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(DateTime.utc_now(), -86_410, :second),
        next_renewal_at: DateTime.add(DateTime.utc_now(), -10, :second),
        quantity: 2,
        provider_billing_ref: "pm_sbh_10_05_unchanged"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    collection = fetch_collection_for_attempt!(attempt.id)
    order = fetch_order!(attempt.order_id)
    mark_collection_successful!(collection)
    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    opts = handoff_opts(handoff)

    {result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(order.id, opts)
      end)

    IO.puts("JC-230 unchanged reconciliation query_count=#{stats.query_count}")
    assert {:ok, :reconciled} = result
    assert stats.query_count > 0
    applied = fetch_subscription!(subscription.id)
    assert applied.current_plan_revision_id == attempt.plan_revision_id
    assert applied.quantity == attempt.quantity
    assert applied.renewal_amount_minor == attempt.amount_minor
    assert applied.renewal_currency == attempt.currency
  end

  test "a bound ContractChange can be applied through its private action" do
    %{contract_change: contract_change} = charged_bound_renewal!("sbh_10_05_action")

    assert Info.action(ContractChange, :apply)

    assert {:ok, applied} =
             contract_change
             |> Ash.Changeset.for_update(:apply, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert applied.status == :applied
  end

  test "extend_period accepts charged fields and excludes future-target projections" do
    action = Info.action(Subscription, :extend_period, :update)

    assert :current_plan_revision_id in action.accept
    assert :quantity in action.accept

    refute :current_contract_change_id in action.accept
    refute :pending_variant_id in action.accept
    refute :pending_subscription_plan_id in action.accept
    refute :pending_renewal_amount_minor in action.accept
    refute :pending_renewal_currency in action.accept
    refute :change_effective_at in action.accept
  end

  test "a bound renewal rejects each mismatch in its immutable ContractChange target" do
    for dimension <- [
          :target_revision,
          :target_variant,
          :quantity,
          :amount,
          :currency,
          :effective_at,
          :subscription_id
        ] do
      fixture = charged_bound_renewal!("sbh_10_05_mismatch_#{dimension}", quantity: 2)

      %{
        subscription: subscription,
        attempt: attempt,
        order: order,
        contract_change: change,
        collection: collection
      } = fixture

      {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

      mismatch_contract_change!(dimension, change, fixture)
      before = fetch_subscription!(subscription.id)

      assert {:error, %{code: "VALIDATION_ERROR"}} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 order.id,
                 handoff_opts(handoff)
               )

      after_subscription = fetch_subscription!(subscription.id)

      assert Map.take(after_subscription, [
               :subscription_plan_id,
               :current_plan_revision_id,
               :variant_id,
               :quantity,
               :renewal_amount_minor,
               :renewal_currency,
               :current_period_start_at,
               :current_period_end_at,
               :aggregate_version
             ]) ==
               Map.take(before, [
                 :subscription_plan_id,
                 :current_plan_revision_id,
                 :variant_id,
                 :quantity,
                 :renewal_amount_minor,
                 :renewal_currency,
                 :current_period_start_at,
                 :current_period_end_at,
                 :aggregate_version
               ])

      assert fetch_contract_change!(change.id).status == :bound_to_renewal
      assert fetch_attempt!(attempt.id).status != :succeeded
    end
  end

  test "a bound retired revision remains the paid renewal target after a newer revision is published" do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      revision: revision,
      collection: collection
    } =
      charged_bound_renewal!("sbh_10_05_retired_revision")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    {:ok, _} =
      revision
      |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
      |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    revised_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 6,
        amount_minor: 9_900,
        currency: "CAD",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "platinum"
      })

    newer_revision = SubscriptionsFixtures.create_plan_revision!(revised_plan)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    applied = fetch_subscription!(subscription.id)
    assert attempt.plan_revision_id == revision.id
    assert applied.current_plan_revision_id == revision.id
    assert applied.subscription_plan_id == revision.subscription_plan_id
    refute applied.current_plan_revision_id == newer_revision.id
  end

  test "paid renewal reconciliation preserves an exact queued N+1 target" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      fixture = charged_bound_renewal!("sbh_10_05_later_target")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_100, currency: "GBP"})

    SubscriptionsFixtures.attach_variant_plan!(
      fixture.contract_change.target_variant_id,
      later_plan.id
    )

    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)
    actor = fixture.customer

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(actor, subscription.id, input)

    before = fetch_subscription!(subscription.id)
    queued_before = fetch_contract_change!(queued.current_contract_change_id)

    {reconciliation_result, stats} =
      RepoStats.capture(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          handoff_opts(handoff)
        )
      end)

    IO.puts("JC-233 paid reconciliation with N+1 target query_count=#{stats.query_count}")
    assert stats.query_count > 0
    assert {:ok, :reconciled} = reconciliation_result

    after_subscription = fetch_subscription!(subscription.id)
    queued_after = fetch_contract_change!(queued_before.id)
    assert after_subscription.current_plan_revision_id == attempt.plan_revision_id
    assert after_subscription.subscription_plan_id == fixture.revision.subscription_plan_id
    assert after_subscription.variant_id == attempt.variant_id
    assert after_subscription.quantity == attempt.quantity
    assert after_subscription.renewal_amount_minor == attempt.amount_minor
    assert after_subscription.renewal_currency == attempt.currency
    assert after_subscription.current_period_start_at == attempt.period_start_at
    assert after_subscription.current_period_end_at == attempt.period_end_at
    assert after_subscription.current_contract_change_id == queued_before.id
    assert after_subscription.pending_subscription_plan_id == before.pending_subscription_plan_id
    assert after_subscription.pending_variant_id == before.pending_variant_id
    assert after_subscription.pending_renewal_amount_minor == before.pending_renewal_amount_minor
    assert after_subscription.pending_renewal_currency == before.pending_renewal_currency
    assert after_subscription.change_effective_at == before.change_effective_at
    assert queued_after.status == :queued
    assert queued_after.subscription_id == subscription.id
    assert queued_after.target_plan_revision_id == later_revision.id
    assert queued_after.target_amount_minor == later_revision.amount_minor
    assert queued_after.target_currency == later_revision.currency
    assert queued_after.effective_at == after_subscription.current_period_end_at
    assert queued_after.target_variant_id == attempt.variant_id
    assert queued_after.target_quantity == attempt.quantity
    assert fetch_contract_change!(attempt.contract_change_id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded

    applied_version = after_subscription.aggregate_version

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.aggregate_version == applied_version
    assert replayed.current_contract_change_id == queued_before.id
    assert fetch_contract_change!(queued_before.id) == queued_after

    assert [attempt.contract_change_id, queued_before.id] ==
             subscription_contract_change_ids!(subscription.id)
  end

  test "paid renewal reconciliation rejects a queued target at the bound boundary" do
    %{subscription: subscription, attempt: attempt, order: order, collection: collection} =
      fixture = charged_bound_renewal!("sbh_10_05_bound_boundary_target")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_100})

    SubscriptionsFixtures.attach_variant_plan!(
      fixture.contract_change.target_variant_id,
      later_plan.id
    )

    SubscriptionsFixtures.create_plan_revision!(later_plan)

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(
               fixture.customer,
               subscription.id,
               input
             )

    queued_before = fetch_contract_change!(queued.current_contract_change_id)
    assert queued_before.effective_at == attempt.period_end_at

    Store.Repo.query!(
      "UPDATE contract_changes SET effective_at = $1 WHERE id = $2",
      [attempt.period_start_at, Ecto.UUID.dump!(queued_before.id)]
    )

    Store.Repo.query!(
      "UPDATE subscriptions SET change_effective_at = $1 WHERE id = $2",
      [attempt.period_start_at, Ecto.UUID.dump!(subscription.id)]
    )

    queued_at_bound_boundary = fetch_contract_change!(queued_before.id)
    before_subscription = fetch_subscription!(subscription.id)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    after_subscription = fetch_subscription!(subscription.id)
    assert after_subscription.aggregate_version == before_subscription.aggregate_version
    assert after_subscription == before_subscription
    assert fetch_contract_change!(queued_before.id) == queued_at_bound_boundary
    assert fetch_contract_change!(attempt.contract_change_id).status == :bound_to_renewal
    assert fetch_attempt!(attempt.id).status != :succeeded
  end

  test "paid renewal reconciliation rejects a broken N+1 predecessor chain" do
    assert_corrupted_n_plus_one_lineage_fails!(:broken_predecessor)
  end

  test "paid renewal reconciliation rejects an invalid N+1 intermediate lifecycle" do
    assert_corrupted_n_plus_one_lineage_fails!(:intermediate_lifecycle)
  end

  test "paid renewal reconciliation rejects a wrong N+1 target boundary" do
    assert_corrupted_n_plus_one_lineage_fails!(:wrong_boundary)
  end

  test "ContractChange apply rejects queued, superseded, and canceled states" do
    for terminal_state <- [:queued, :superseded, :canceled] do
      %{contract_change: change} = charged_bound_renewal!("sbh_10_05_apply_#{terminal_state}")

      Store.Repo.query!(
        "UPDATE contract_changes SET status = $1 WHERE id = $2",
        [Atom.to_string(terminal_state), Ecto.UUID.dump!(change.id)]
      )

      current = fetch_contract_change!(change.id)

      assert {:error, _} =
               current
               |> Ash.Changeset.for_update(:apply, %{}, context: %{system?: true})
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: %{system?: true}
               )

      assert fetch_contract_change!(change.id).status == terminal_state
    end
  end

  test "retry after the access-sync crash preserves a later target and reuses the charged entitlement snapshot",
       %{sandbox_owners: sandbox_owners} do
    %{
      subscription: subscription,
      attempt: attempt,
      order: order,
      customer: customer,
      contract_change: contract_change,
      collection: collection,
      revision: revision
    } =
      charged_bound_renewal!("sbh_10_05_crash_replay")

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    later_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 8_300, currency: "GBP"})

    SubscriptionsFixtures.attach_variant_plan!(contract_change.target_variant_id, later_plan.id)
    later_revision = SubscriptionsFixtures.create_plan_revision!(later_plan)

    {:ok, queued} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => later_plan.id
      })

    assert {:ok, queued_subscription} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, queued)

    later_change = fetch_contract_change!(queued_subscription.current_contract_change_id)
    future_projection = fetch_subscription!(subscription.id)

    crash_once = :atomics.new(1, [])
    handler_id = "jc230-crash-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :paid_renewal_access_sync],
        fn _event, _measurements, _metadata, state ->
          if :atomics.compare_exchange(state, 1, 0, 1) == :ok do
            send(parent, {:jc230_crashing_reconciliation, self()})
            Process.exit(self(), :kill)
          end
        end,
        crash_once
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {child, monitor} =
      spawn_monitor(fn ->
        receive do
          :start_reconciliation ->
            Facade.reconcile_paid_subscription_renewal_for_system(
              order.id,
              handoff_opts(handoff)
            )
        end
      end)

    :ok = Sandbox.allow(Store.Repo, sandbox_owners[Store.Repo], child)
    :ok = Sandbox.allow(Store.DirectRepo, sandbox_owners[Store.DirectRepo], child)
    send(child, :start_reconciliation)
    assert_receive {:jc230_crashing_reconciliation, ^child}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 1_000

    committed = fetch_subscription!(subscription.id)
    assert committed.current_plan_revision_id == revision.id
    assert committed.current_period_end_at == attempt.period_end_at
    assert committed.current_contract_change_id == later_change.id

    assert committed.pending_subscription_plan_id ==
             future_projection.pending_subscription_plan_id

    assert committed.pending_variant_id == future_projection.pending_variant_id

    assert committed.pending_renewal_amount_minor ==
             future_projection.pending_renewal_amount_minor

    assert committed.pending_renewal_currency == future_projection.pending_renewal_currency
    assert committed.change_effective_at == future_projection.change_effective_at
    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status != :succeeded
    version = fetch_subscription!(subscription.id).aggregate_version
    :ok = :telemetry.detach(handler_id)

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               order.id,
               handoff_opts(handoff)
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.aggregate_version == version
    assert replayed.current_period_end_at == attempt.period_end_at
    assert replayed.current_contract_change_id == later_change.id
    assert replayed.pending_subscription_plan_id == future_projection.pending_subscription_plan_id
    assert replayed.pending_variant_id == future_projection.pending_variant_id
    assert replayed.pending_renewal_amount_minor == future_projection.pending_renewal_amount_minor
    assert replayed.pending_renewal_currency == future_projection.pending_renewal_currency
    assert replayed.change_effective_at == future_projection.change_effective_at
    assert fetch_contract_change!(later_change.id) == later_change
    assert later_change.status == :queued
    assert later_change.target_plan_revision_id == later_revision.id
    assert later_change.target_variant_id == attempt.variant_id
    assert later_change.target_quantity == attempt.quantity
    assert later_change.effective_at == attempt.period_end_at

    assert [contract_change.id, later_change.id] ==
             subscription_contract_change_ids!(subscription.id)

    assert fetch_contract_change!(contract_change.id).status == :applied
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert replayed.membership_key == "gold"

    assert [%EntitlementGrant{kind: :membership_access, scope_key: "gold", status: :active}] =
             active_grants_for(subscription.id)
  end

  defp charged_bound_renewal!(token, opts \\ []) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_100,
        currency: "USD"
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 2,
        amount_minor: 4_700,
        currency: "EUR",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "gold"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    quantity = Keyword.get(opts, :quantity, 1)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second),
        quantity: quantity,
        provider_billing_ref: "pm_#{token}"
      })

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, queued} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, input)

    contract_change = fetch_contract_change!(queued.current_contract_change_id)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt = fetch_attempt_for_subscription!(subscription.id)
    assert attempt.contract_change_id == contract_change.id
    order = fetch_order!(attempt.order_id)
    collection = fetch_collection_for_attempt!(attempt.id)
    mark_collection_successful!(collection)

    %{
      subscription: subscription,
      customer: customer,
      attempt: fetch_attempt!(attempt.id),
      order: order,
      collection: fetch_collection!(collection.id),
      revision: revision,
      contract_change: fetch_contract_change!(contract_change.id)
    }
  end

  defp queue_post_b_lineage_targets!(fixture, _token) do
    [first_y, z] =
      for amount_minor <- [6_100, 7_300] do
        plan =
          SubscriptionsFixtures.create_subscription_plan!(%{
            amount_minor: amount_minor,
            currency: "GBP"
          })

        SubscriptionsFixtures.attach_variant_plan!(
          fixture.contract_change.target_variant_id,
          plan.id
        )

        SubscriptionsFixtures.create_plan_revision!(plan)

        {:ok, input} =
          QueueSubscriptionPlanChangeInput.new(%{
            "subscription_id" => fixture.subscription.id,
            "subscription_plan_id" => plan.id
          })

        assert {:ok, queued} =
                 Facade.queue_subscription_plan_change_for_user(
                   fixture.customer,
                   fixture.subscription.id,
                   input
                 )

        fetch_contract_change!(queued.current_contract_change_id)
      end

    y = fetch_contract_change!(first_y.id)

    assert y.status == :superseded
    assert z.status == :queued
    assert y.predecessor_contract_change_id == fixture.contract_change.id
    assert z.predecessor_contract_change_id == y.id
    assert z.effective_at == fixture.attempt.period_end_at

    {y, z}
  end

  defp corrupt_n_plus_one_lineage!(:broken_predecessor, fixture, _y, z) do
    Store.Repo.query!(
      "UPDATE contract_changes SET predecessor_contract_change_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(fixture.contract_change.id), Ecto.UUID.dump!(z.id)]
    )
  end

  defp corrupt_n_plus_one_lineage!(:intermediate_lifecycle, _fixture, y, _z) do
    Store.Repo.query!("UPDATE contract_changes SET status = 'applied' WHERE id = $1", [
      Ecto.UUID.dump!(y.id)
    ])
  end

  defp corrupt_n_plus_one_lineage!(:wrong_boundary, fixture, _y, z) do
    Store.Repo.query!("UPDATE contract_changes SET effective_at = $1 WHERE id = $2", [
      fixture.attempt.period_start_at,
      Ecto.UUID.dump!(z.id)
    ])
  end

  defp assert_corrupted_n_plus_one_lineage_fails!(corruption) do
    token = "sbh_10_05_lineage_#{corruption}_#{System.unique_integer([:positive])}"
    fixture = charged_bound_renewal!(token)
    %{subscription: subscription, attempt: attempt, collection: collection} = fixture
    {y, z} = queue_post_b_lineage_targets!(fixture, token)

    corrupt_n_plus_one_lineage!(corruption, fixture, y, z)

    before_subscription = fetch_subscription!(subscription.id)
    before_attempt = fetch_attempt!(attempt.id)
    before_x = fetch_contract_change!(fixture.contract_change.id)
    before_y = fetch_contract_change!(y.id)
    before_z = fetch_contract_change!(z.id)

    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert before_subscription.current_contract_change_id == z.id
    assert before_x.status == :bound_to_renewal

    assert before_y.status ==
             if(corruption == :intermediate_lifecycle, do: :applied, else: :superseded)

    assert before_z.status == :queued

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.reconcile_paid_subscription_renewal_for_system(
               fixture.order.id,
               handoff_opts(handoff)
             )

    assert fetch_subscription!(subscription.id) == before_subscription
    assert fetch_attempt!(attempt.id) == before_attempt
    assert fetch_contract_change!(fixture.contract_change.id) == before_x
    assert fetch_contract_change!(y.id) == before_y
    assert fetch_contract_change!(z.id) == before_z
  end

  defp create_other_payment_intent!(subscription, order) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create,
      %{
        order_id: order.id,
        amount_received_minor: 0,
        currency: order.currency_code,
        provider: subscription.provider,
        subscription_id: subscription.id,
        payment_intent_key: "sbh_10_05_other_pi:#{Ecto.UUID.generate()}"
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mismatch_contract_change!(dimension, change, fixture) do
    {field, value} = mismatch_contract_change_target(dimension, fixture)

    Store.Repo.query!("UPDATE contract_changes SET #{field} = $1 WHERE id = $2", [
      value,
      Ecto.UUID.dump!(change.id)
    ])
  end

  defp mismatch_contract_change_target(:target_revision, _fixture) do
    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        amount_minor: 7_777,
        currency: "CAD"
      })

    revision = SubscriptionsFixtures.create_plan_revision!(plan)
    {:target_plan_revision_id, Ecto.UUID.dump!(revision.id)}
  end

  defp mismatch_contract_change_target(:target_variant, _fixture) do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    {:target_variant_id, Ecto.UUID.dump!(variant.id)}
  end

  defp mismatch_contract_change_target(:quantity, fixture),
    do: {:target_quantity, fixture.attempt.quantity + 1}

  defp mismatch_contract_change_target(:amount, fixture),
    do: {:target_amount_minor, fixture.attempt.amount_minor + 1}

  defp mismatch_contract_change_target(:currency, fixture) do
    currency = if fixture.attempt.currency == "USD", do: "EUR", else: "USD"
    {:target_currency, currency}
  end

  defp mismatch_contract_change_target(:effective_at, fixture) do
    effective_at = DateTime.add(fixture.attempt.period_start_at, 1, :second)
    {:effective_at, effective_at}
  end

  defp mismatch_contract_change_target(:subscription_id, _fixture) do
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()

    other_customer =
      SubscriptionsFixtures.create_customer!(
        "sbh_10_05_foreign_#{System.unique_integer([:positive])}"
      )

    %{subscription: other} =
      SubscriptionsFixtures.create_subscription_fixture!(other_customer.id, variant, plan)

    {:subscription_id, Ecto.UUID.dump!(other.id)}
  end

  defp mark_collection_successful!(collection) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    {reference, kind} =
      cond do
        is_binary(payment_intent.provider_payment_id) ->
          {payment_intent.provider_payment_id, :payment_intent}

        is_binary(payment_intent.provider_session_id) ->
          {payment_intent.provider_session_id, :checkout_session}

        true ->
          {payment_intent.provider_request_reference, :transaction_reference}
      end

    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: reference,
      provider_reference_kind: kind,
      provider_transaction_id: payment_intent.provider_payment_id || "pi_#{payment_intent.id}",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert outcome in [:authoritative_success, :already_applied_success]
    updated = fetch_collection!(collection.id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated.payment_attempt_id,
                 payment_intent_id: collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp fetch_subscription!(id), do: read_one!(Subscription, id, Store.Subscriptions)
  defp fetch_attempt!(id), do: read_one!(RenewalAttempt, id, Store.Subscriptions)
  defp fetch_contract_change!(id), do: read_one!(ContractChange, id, Store.Subscriptions)
  defp fetch_order!(id), do: read_one!(Order, id, Store.Orders)
  defp fetch_payment_intent!(id), do: read_one!(PaymentIntent, id, Store.Payments)
  defp fetch_collection!(id), do: read_one!(RenewalCollectionAttempt, id, Store.Subscriptions)

  defp subscription_contract_change_ids!(subscription_id) do
    ContractChange
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(ordering_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> Enum.map(& &1.id)
  end

  defp read_one!(resource, id, domain) do
    resource
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: domain, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_for_attempt!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp active_grants_for(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_id == ^subscription_id and status == :active))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt_for_subscription!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
