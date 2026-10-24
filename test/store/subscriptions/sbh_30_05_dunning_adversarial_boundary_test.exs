defmodule Store.Subscriptions.Sbh3005DunningAdversarialBoundaryTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.Order
  alias Store.Payments.Inputs.ValidateRenewalCollectionOutcomeInput
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Providers
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo

  alias Store.Subscriptions.{
    Facade,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.{PaymentIntentBindingInput, StartInput}

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @system_context %{system?: true}

  setup context do
    previous_payments = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn -> Application.put_env(:store, :payments, previous_payments) end)

    :ok
  end

  describe "retry timing" do
    # Invariant: due selection is false one microsecond before the persisted retry time, and true at and after it.
    # Mutation caught: changing the selector comparison from <= to < drops the exact-time retry.
    test "selects a retry before, at, and after its persisted timestamp" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_retry_offsets", now,
          max_retry_attempts: 2,
          retry_schedule_hours: [1, 24],
          grace_period_days: 7
        )

      assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
      failed = fetch_subscription!(subscription.id)
      assert failed.status == :past_due
      assert %DateTime{} = failed.next_retry_at
      retry_at = failed.next_retry_at
      assert retry_at == DateTime.add(now, 1, :hour)

      before_retry_at = DateTime.add(retry_at, -1, :microsecond)
      assert due_retry?(subscription.id, before_retry_at) == false

      assert {:ok, %{due_count: 0}} =
               Facade.run_due_renewals_for_system(now: before_retry_at, limit: 20)

      assert due_retry?(subscription.id, retry_at)
      assert due_retry?(subscription.id, DateTime.add(retry_at, 1, :microsecond))

      assert {:ok, %{due_count: 1, failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: retry_at, limit: 20)

      retried = fetch_subscription!(subscription.id)
      assert retried.status == :past_due
      assert retried.dunning_attempt_count == 2
    end
  end

  describe "failed-payment boundary timing" do
    # Invariant: boundary selection excludes T-1µs and includes T and T+1µs; execution suspends only once.
    # Mutation caught: changing the boundary selector from <= to < drops the exact-time transition.
    test "selects the explicit boundary and suspends once at equality" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_boundary_offsets", now,
          max_retry_attempts: 0,
          retry_schedule_hours: [0],
          grace_period_days: 0
        )

      assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
      past_due = fetch_subscription!(subscription.id)
      boundary_at = past_due.failed_payment_boundary_at

      assert boundary_at == now
      refute subscription.id in due_boundary_ids(DateTime.add(boundary_at, -1, :microsecond))
      assert subscription.id in due_boundary_ids(boundary_at)
      assert subscription.id in due_boundary_ids(DateTime.add(boundary_at, 1, :microsecond))

      assert {:ok, %{due_count: 0, suspended_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(boundary_at, -1, :microsecond),
                 limit: 20
               )

      assert fetch_subscription!(subscription.id).status == :past_due

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).status == :suspended

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(boundary_at, 1, :microsecond),
                 limit: 20
               )
    end
  end

  describe "provider checkpoint boundary" do
    # Invariant: equality with the persisted boundary is denied by the provider claim's strict SQL comparator.
    # Mutation caught: changing the atomic claim predicate from < to <= permits dispatch at equality.
    test "provider claim SQL keeps the strict database-clock-before-boundary contract" do
      source = File.read!("lib/store/subscriptions/renewal_collection_attempts.ex")

      [_before_claim, claim_and_after] =
        String.split(source, "defp claim_collection_dispatch(", parts: 2)

      [claim_code, _after_claim] =
        String.split(claim_and_after, "defp collection_boundary_claim_allowed?", parts: 2)

      normalized = String.replace(claim_code, ~r/\s+/, " ")

      assert String.contains?(normalized, "clock_timestamp() < $5::timestamptz")
      refute String.contains?(normalized, "clock_timestamp() <= $5::timestamptz")
    end

    # Invariant: a retry strictly before its bound boundary can cross the atomic dispatch claim once.
    # Mutation caught: moving provider submission before the claim leaves not_started in provider evidence.
    test "a retry before the boundary starts one exact collection once" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!(
          "jc240_preboundary_start",
          now,
          [max_retry_attempts: 1, retry_schedule_hours: [0], grace_period_days: 7],
          %{provider_billing_ref: "pm_jc240_preboundary"}
        )

      parent = self()
      calls = :atomics.new(1, [])
      stub_collection_requests!(parent, calls, ["canceled", "processing"])

      assert {:error, %{code: "PAYMENT_FAILED"}} =
               Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

      failed = fetch_subscription!(subscription.id)
      assert failed.status == :past_due
      assert failed.next_retry_at == now
      assert DateTime.compare(now, failed.failed_payment_boundary_at) == :lt

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(subscription.id,
                 now: failed.next_retry_at
               )

      assert :atomics.get(calls, 1) == 2
      [first_request, retry_request] = drain_provider_requests()
      assert first_request.number == 1
      assert retry_request.number == 2
      assert first_request.collection_id != retry_request.collection_id
      assert first_request.dispatch_state == "may_have_been_reached"
      assert retry_request.dispatch_state == "may_have_been_reached"
      assert retry_request.idempotency_key == "renewal-collection:" <> retry_request.collection_id

      attempt = fetch_current_attempt!(subscription.id)
      assert first_request.renewal_attempt_id == attempt.id
      assert retry_request.renewal_attempt_id == attempt.id

      assert [%RenewalCollectionAttempt{} = first, %RenewalCollectionAttempt{} = retry] =
               list_collections!(attempt.id)

      assert first.id == first_request.collection_id
      assert retry.id == retry_request.collection_id
      assert first.dispatch_state == :may_have_been_reached
      assert retry.dispatch_state == :may_have_been_reached
    end

    # Invariant: the persisted retry intent cannot authorize dispatch after the live DB boundary is reached.
    # Mutation caught: removing the database-clock boundary predicate lets the second POST reach Stripe.
    test "a retry scheduled at boundary equality has zero provider mutation after the boundary is persisted" do
      assert_boundary_retry_denied!("jc240_at_boundary", 0)
    end

    # Invariant: a persisted boundary one microsecond behind the claim still prevents provider dispatch.
    # Mutation caught: removing the database-clock boundary predicate lets the second POST reach Stripe.
    test "a retry scheduled after boundary equality has zero provider mutation after the boundary is persisted" do
      assert_boundary_retry_denied!("jc240_after_boundary", 1)
    end

    # Invariant: a checkpointed collection remains reconcilable after suspension.
    # Mutation caught: starting a replacement collection creates a second provider mutation.
    test "a reached collection remains recoverable after the boundary" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!(
          "jc240_inflight_boundary",
          now,
          [max_retry_attempts: 2, retry_schedule_hours: [0, 24], grace_period_days: 7],
          %{provider_billing_ref: "pm_jc240_inflight"}
        )

      parent = self()
      calls = :atomics.new(1, [])
      stub_collection_requests!(parent, calls, ["processing"])

      assert {:ok, :processed} =
               Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

      [request] = drain_provider_requests()
      assert :atomics.get(calls, 1) == 1
      attempt = fetch_current_attempt!(subscription.id)
      [collection] = list_collections!(attempt.id)
      assert collection.id == request.collection_id
      assert collection.dispatch_state == :may_have_been_reached

      boundary_at = DateTime.add(db_now!(), -1, :second)

      Repo.query!(
        "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, past_due_since_at = $2, failed_payment_boundary_at = $3, next_retry_at = NULL, retry_suppressed_at = $2 WHERE id = $1",
        [Ecto.UUID.dump!(subscription.id), DateTime.add(boundary_at, -7, :day), boundary_at]
      )

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert {:ok, recovered} =
               RenewalCollectionAttempts.recover_reached_for_subscription_for_system(
                 subscription.id,
                 boundary_at
               )

      assert recovered.collection_attempt.id == collection.id
      assert recovered.payment_intent.id == collection.payment_intent_id
      assert recovered.collection_attempt.dispatch_state == :may_have_been_reached
      assert length(list_collections!(attempt.id)) == 1
      assert :atomics.get(calls, 1) == 1
      assert drain_provider_requests() == []
    end
  end

  describe "retry exhaustion composition" do
    # Invariant: exhausting the retry budget suppresses retries but preserves PAST_DUE and its bound boundary.
    # Mutation caught: converting exhaustion to SUSPENDED or EXPIRED, or clearing the independent boundary.
    test "exhausted PAST_DUE leaves retry selection and remains boundary-discoverable" do
      first_failure_at = DateTime.add(db_now!(), -30, :day)

      %{subscription: subscription} =
        create_due_subscription!("jc240_exhausted", first_failure_at,
          max_retry_attempts: 1,
          retry_schedule_hours: [0, 24],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("retry exhaustion must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      first_failure = fetch_subscription!(subscription.id)
      boundary_at = first_failure.failed_payment_boundary_at
      assert first_failure.status == :past_due
      assert first_failure.next_retry_at == first_failure_at
      assert DateTime.compare(first_failure.next_retry_at, boundary_at) == :lt

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure.next_retry_at, limit: 20)

      exhausted = fetch_subscription!(subscription.id)
      assert exhausted.status == :past_due
      assert exhausted.dunning_attempt_count == 2
      assert %DateTime{} = exhausted.retry_suppressed_at
      assert is_nil(exhausted.next_retry_at)
      assert exhausted.failed_payment_boundary_at == boundary_at
      refute due_retry?(subscription.id, boundary_at)
      assert subscription.id in due_boundary_ids(boundary_at)

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.aggregate_version == exhausted.aggregate_version + 1

      [effect] = access_effect_rows!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.status == "required"
      assert effect.disposition == "non_effective"
      assert is_nil(effect.valid_from_at)
      effects_after_suspension = access_effect_rows!(subscription.id)
      suspended_version = suspended.aggregate_version

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended_version
      assert access_effect_rows!(subscription.id) == effects_after_suspension
      assert provider_mutation_count() == 0
    end

    # Invariant: max_retry_attempts=0 suppresses the first retry while preserving boundary discovery.
    # Mutation caught: allowing retry selection or removing the row from the failed-payment selector.
    test "zero retries reaches SUSPENDED through the independent boundary path" do
      first_failure_at = DateTime.add(db_now!(), -30, :day)

      %{subscription: subscription} =
        create_due_subscription!("jc240_zero_retry", first_failure_at,
          max_retry_attempts: 0,
          retry_schedule_hours: [0, 24],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("zero retry allowance must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      exhausted = fetch_subscription!(subscription.id)
      boundary_at = exhausted.failed_payment_boundary_at
      assert exhausted.status == :past_due
      assert exhausted.dunning_attempt_count == 1
      assert %DateTime{} = exhausted.retry_suppressed_at
      assert is_nil(exhausted.next_retry_at)
      refute due_retry?(subscription.id, boundary_at)
      assert subscription.id in due_boundary_ids(boundary_at)

      assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.aggregate_version == exhausted.aggregate_version + 1
      [effect] = access_effect_rows!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.disposition == "non_effective"
      assert is_nil(effect.valid_from_at)

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended.aggregate_version
      assert provider_mutation_count() == 0
    end

    # Invariant: changing current Plan and PlanRevision after binding cannot alter the bound retry or boundary policy.
    # Mutation caught: reading retry count, retry offsets, grace, or access policy from the mutable current Plan.
    test "mutable Plan changes cannot rewrite a bound dunning episode" do
      first_failure_at = db_now!()

      %{subscription: subscription, plan: plan} =
        create_due_subscription!("jc240_bound_policy", first_failure_at,
          max_retry_attempts: 3,
          retry_schedule_hours: [2, 5, 72],
          grace_period_days: 7
        )

      StripeAPIStub.stub_unexpected!("missing current chargeability must not reach Stripe")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure_at, limit: 20)

      first_failure = fetch_subscription!(subscription.id)
      attempt = fetch_current_attempt!(subscription.id)
      boundary_at = first_failure.failed_payment_boundary_at
      assert attempt.charged_contract_snapshot["retry_schedule_hours"] == [2, 5, 72]
      assert attempt.charged_contract_snapshot["max_retry_attempts"] == 3
      assert attempt.charged_contract_snapshot["grace_period_days"] == 7
      assert attempt.charged_contract_snapshot["access_on_past_due"] == "keep_during_grace"
      assert first_failure.next_retry_at == DateTime.add(first_failure_at, 2, :hour)
      baseline_effects = access_effect_rows!(subscription.id)

      updated_plan =
        plan
        |> Ash.Changeset.for_update(
          :update,
          %{
            max_retry_attempts: 0,
            retry_schedule_hours: [0],
            grace_period_days: 0,
            access_on_past_due: :remove_immediately
          },
          context: @system_context
        )
        |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: @system_context)

      {:ok, old_revision} =
        PlanRevision.get_effective_for_plan(plan.id,
          authorize?: false,
          context: @system_context
        )

      assert {:ok, retired_revision} =
               old_revision
               |> Ash.Changeset.for_update(:retire, %{}, context: @system_context)
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: @system_context
               )

      assert retired_revision.status == :retired
      new_revision = SubscriptionsFixtures.create_plan_revision!(updated_plan)
      assert new_revision.id != attempt.plan_revision_id
      assert new_revision.status == :effective

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: first_failure.next_retry_at, limit: 20)

      after_retry = fetch_subscription!(subscription.id)
      assert after_retry.status == :past_due
      assert after_retry.dunning_attempt_count == 2
      assert after_retry.failed_payment_boundary_at == boundary_at
      assert after_retry.next_retry_at == DateTime.add(first_failure_at, 5, :hour)
      assert is_nil(after_retry.retry_suppressed_at)

      assert fetch_current_attempt!(subscription.id).charged_contract_snapshot ==
               attempt.charged_contract_snapshot

      assert updated_plan.access_on_past_due == :remove_immediately
      assert access_effect_rows!(subscription.id) == baseline_effects
      assert provider_mutation_count() == 0
    end
  end

  describe "success and failure ordering" do
    # Invariant: the last authorized retry may cross before the boundary and apply one exact paid period.
    # Mutation caught: suppressing the final allowed retry or reapplying the period/effect on boundary replay.
    test "final authorized retry succeeds before the boundary and makes the later sweep stale" do
      occurrence =
        create_failed_then_inflight_occurrence!("jc240_final_retry_success",
          max_retry_attempts: 1
        )

      failed = fetch_subscription!(occurrence.subscription.id)
      boundary_at = failed.failed_payment_boundary_at
      assert failed.status == :past_due
      assert failed.dunning_attempt_count == 1
      assert failed.next_retry_at == occurrence.now
      assert DateTime.compare(occurrence.now, boundary_at) == :lt
      assert occurrence.inflight_collection.dispatch_state == :may_have_been_reached

      mark_collection_successful!(occurrence.inflight_collection, db_now!())

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.inflight_collection.id)

      before_success = fetch_subscription!(occurrence.subscription.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      assert active.status == :active
      assert active.current_period_start_at == occurrence.attempt.period_start_at
      assert active.current_period_end_at == occurrence.attempt.period_end_at
      assert active.aggregate_version == before_success.aggregate_version + 1
      assert active.dunning_attempt_count == 0
      assert is_nil(active.failed_payment_boundary_at)
      effects_after_success = access_effect_rows!(occurrence.subscription.id)

      assert Enum.count(effects_after_success, &(&1.source_version == active.aggregate_version)) <=
               1

      assert length(Enum.uniq_by(effects_after_success, & &1.source_version)) ==
               length(effects_after_success)

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      final = fetch_subscription!(occurrence.subscription.id)
      assert final.aggregate_version == active.aggregate_version
      assert final.current_period_end_at == active.current_period_end_at
      assert access_effect_rows!(occurrence.subscription.id) == effects_after_success
    end

    # Invariant: exact success recovers exhausted PAST_DUE once; replay leaves period and targets unchanged.
    # Mutation caught: retaining dunning state or applying the paid period/effect twice.
    test "exact success recovers exhausted PAST_DUE once and replay is inert" do
      occurrence = create_bound_occurrence!("jc240_exhausted_success")
      past_due_since_at = DateTime.add(occurrence.now, -6, :day)
      boundary_at = DateTime.add(past_due_since_at, 7, :day)

      exhausted =
        mark_past_due!(occurrence.subscription.id, %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: past_due_since_at,
          failed_payment_boundary_at: boundary_at,
          dunning_attempt_count: 4,
          next_retry_at: nil,
          retry_suppressed_at: occurrence.now
        })

      assert exhausted.status == :past_due
      assert boundary_at == DateTime.add(occurrence.now, 1, :day)
      refute due_retry?(occurrence.subscription.id, boundary_at)

      mark_collection_successful!(occurrence.collection, db_now!())

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      recovered = fetch_subscription!(occurrence.subscription.id)
      assert recovered.status == :active
      assert recovered.current_period_start_at == occurrence.attempt.period_start_at
      assert recovered.current_period_end_at == occurrence.attempt.period_end_at
      assert recovered.dunning_attempt_count == 0
      assert is_nil(recovered.past_due_since_at)
      assert is_nil(recovered.failed_payment_boundary_at)
      assert is_nil(recovered.retry_suppressed_at)
      assert is_nil(recovered.next_retry_at)

      effects_after_recovery = access_effect_rows!(occurrence.subscription.id)

      assert Enum.count(
               effects_after_recovery,
               &(&1.source_version == recovered.aggregate_version)
             ) <= 1

      assert length(Enum.uniq_by(effects_after_recovery, & &1.source_version)) ==
               length(effects_after_recovery)

      assert Enum.count(effects_after_recovery, &(&1.disposition == "effective")) <= 1

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      replayed = fetch_subscription!(occurrence.subscription.id)
      assert replayed.aggregate_version == recovered.aggregate_version
      assert replayed.current_period_end_at == recovered.current_period_end_at
      assert access_effect_rows!(occurrence.subscription.id) == effects_after_recovery
    end

    # Invariant: exact current occurrence recovers PAST_DUE or SUSPENDED after failure evidence.
    # Mutation caught: rejecting an authorized same-occurrence success or recovering from another occurrence.
    test "late exact success recovers the same occurrence from PAST_DUE and SUSPENDED" do
      Enum.each([:past_due, :suspended], fn source_status ->
        occurrence = create_failed_then_inflight_occurrence!("jc240_late_#{source_status}")

        source =
          if source_status == :suspended do
            set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

            assert {:ok, %{suspended_count: 1}} =
                     Facade.run_due_failed_payment_suspensions_for_system(
                       now: db_now!(),
                       limit: 20
                     )

            fetch_subscription!(occurrence.subscription.id)
          else
            fetch_subscription!(occurrence.subscription.id)
          end

        assert source.status == source_status
        assert occurrence.inflight_collection.renewal_attempt_id == occurrence.attempt.id

        mark_collection_successful!(occurrence.inflight_collection, db_now!())

        {:ok, handoff} =
          RenewalCollectionAttempts.success_handoff_for_system(occurrence.inflight_collection.id)

        assert {:ok, :reconciled} =
                 Facade.reconcile_paid_subscription_renewal_for_system(
                   occurrence.order.id,
                   handoff_opts(handoff)
                 )

        recovered = fetch_subscription!(occurrence.subscription.id)
        assert recovered.status == :active
        assert recovered.current_period_start_at == occurrence.attempt.period_start_at
        assert recovered.current_period_end_at == occurrence.attempt.period_end_at
        assert is_nil(recovered.past_due_since_at)
        assert is_nil(recovered.failed_payment_boundary_at)
        assert is_nil(recovered.retry_suppressed_at)
        assert is_nil(recovered.next_retry_at)
        assert fetch_current_attempt!(occurrence.subscription.id).id == occurrence.attempt.id
      end)
    end

    # Invariant: authoritative success cannot be regressed by later failure evidence.
    # Mutation caught: applying stale failure after success moves the Subscription back into dunning.
    test "success first keeps stale failure observation from regressing dunning or access" do
      occurrence = create_bound_occurrence!("jc240_success_first")
      mark_collection_successful!(occurrence.collection, db_now!())

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      active_effects = access_effect_rows!(occurrence.subscription.id)
      payment_intent = fetch_payment_intent!(occurrence.collection.payment_intent_id)
      _late_failure = record_failure_observation!(payment_intent, db_now!())

      assert {:ok, %{due_count: 0, suspended_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(
                 now: DateTime.add(occurrence.attempt.period_end_at, 30, :day),
                 limit: 20
               )

      unchanged = fetch_subscription!(occurrence.subscription.id)
      assert unchanged.status == :active
      assert unchanged.aggregate_version == active.aggregate_version
      assert is_nil(unchanged.failed_payment_boundary_at)
      assert is_nil(unchanged.past_due_since_at)
      assert is_nil(unchanged.retry_suppressed_at)
      assert is_nil(unchanged.next_retry_at)
      assert access_effect_rows!(occurrence.subscription.id) == active_effects

      assert Enum.all?(
               list_collections!(occurrence.attempt.id),
               &(&1.id == occurrence.collection.id)
             )

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      assert fetch_subscription!(occurrence.subscription.id).aggregate_version ==
               active.aggregate_version
    end

    # Invariant: replay for one failed collection identity cannot multiply dunning or communications.
    # Mutation caught: applying the same collection failure twice increments retry count or creates another effect row.
    test "duplicate failure observation leaves dunning, retry, access, and outbox evidence unchanged" do
      occurrence = create_failed_then_inflight_occurrence!("jc240_duplicate_failure")
      before = fetch_subscription!(occurrence.subscription.id)
      before_effects = access_effect_rows!(occurrence.subscription.id)
      before_outbox_count = email_outbox_count(occurrence.subscription.id)
      before_collections = Enum.map(list_collections!(occurrence.attempt.id), & &1.id)
      first_payment_intent = fetch_payment_intent!(occurrence.failed_collection.payment_intent_id)

      _replayed_observation = record_failure_observation!(first_payment_intent, db_now!())

      after_replay = fetch_subscription!(occurrence.subscription.id)
      assert after_replay.status == before.status
      assert after_replay.dunning_attempt_count == before.dunning_attempt_count
      assert after_replay.next_retry_at == before.next_retry_at
      assert after_replay.retry_suppressed_at == before.retry_suppressed_at
      assert after_replay.failed_payment_boundary_at == before.failed_payment_boundary_at
      assert after_replay.aggregate_version == before.aggregate_version
      assert access_effect_rows!(occurrence.subscription.id) == before_effects
      assert email_outbox_count(occurrence.subscription.id) == before_outbox_count
      assert Enum.map(list_collections!(occurrence.attempt.id), & &1.id) == before_collections
      assert fetch_current_attempt!(occurrence.subscription.id).id == occurrence.attempt.id
    end
  end

  describe "terminal guards and access target ordering" do
    # Invariant: CANCELED and EXPIRED cannot use same-occurrence success to recover suspension.
    # Mutation caught: admitting SUSPENDED recovery from either terminal state.
    test "terminal subscriptions stay terminal after exact payment success" do
      Enum.each([:canceled, :expired], fn terminal_status ->
        occurrence = create_bound_occurrence!("jc240_terminal_#{terminal_status}")
        set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

        assert {:ok, %{suspended_count: 1}} =
                 Facade.run_due_failed_payment_suspensions_for_system(now: db_now!(), limit: 20)

        suspended = fetch_subscription!(occurrence.subscription.id)

        transition =
          if terminal_status == :canceled,
            do: :cancel_now_transition,
            else: :mark_expired_transition

        assert {:ok, _terminal} =
                 suspended
                 |> Ash.Changeset.for_update(transition, %{}, context: @system_context)
                 |> Ash.update(
                   domain: Store.Subscriptions,
                   authorize?: false,
                   context: @system_context
                 )

        mark_collection_successful!(occurrence.collection, db_now!())

        {:ok, handoff} =
          RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

        result =
          Facade.reconcile_paid_subscription_renewal_for_system(
            occurrence.order.id,
            handoff_opts(handoff)
          )

        assert fetch_subscription!(occurrence.subscription.id).status == terminal_status
        assert fetch_current_attempt!(occurrence.subscription.id).status != :succeeded

        assert Enum.all?(
                 access_effect_rows!(occurrence.subscription.id),
                 &(&1.disposition == "non_effective")
               )

        assert match?({:ok, :noop}, result) or match?({:error, _}, result)
      end)
    end

    # Invariant: suspension target N is superseded by an effective recovery target at N+1.
    # Mutation caught: reusing N for recovery or allowing the older suspension effect to become current again.
    test "suspension and recovery AccessEffect versions increase monotonically" do
      occurrence = create_bound_occurrence!("jc240_access_order")
      boundary_at = set_boundary_in_past!(occurrence.subscription.id, occurrence.now)

      assert {:ok, %{suspended_count: 1}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(occurrence.subscription.id)
      [suspension_effect] = access_effect_rows!(occurrence.subscription.id)
      assert suspension_effect.source_version == suspended.aggregate_version
      assert suspension_effect.disposition == "non_effective"

      mark_collection_successful!(occurrence.collection, db_now!())

      {:ok, handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 occurrence.order.id,
                 handoff_opts(handoff)
               )

      active = fetch_subscription!(occurrence.subscription.id)
      effects = access_effect_rows!(occurrence.subscription.id)
      assert active.status == :active
      assert active.aggregate_version == suspended.aggregate_version + 1
      assert length(effects) == 2
      [recovery_effect, old_effect] = Enum.sort_by(effects, & &1.source_version, :desc)
      assert recovery_effect.source_version == suspension_effect.source_version + 1
      assert recovery_effect.source_version == active.aggregate_version
      assert recovery_effect.status == "applied"
      assert recovery_effect.disposition == "effective"

      assert recovery_effect.valid_from_at ==
               DateTime.to_naive(occurrence.attempt.period_start_at)

      assert recovery_effect.valid_until_at == DateTime.to_naive(active.current_period_end_at)

      assert old_effect.source_version == suspension_effect.source_version
      assert old_effect.status == "superseded"
      assert old_effect.disposition == "non_effective"
      assert is_nil(old_effect.valid_from_at)
      assert Enum.count(effects, &(&1.disposition == "effective")) == 1
    end
  end

  describe "occurrence and boundary concurrency" do
    # Invariant: success evidence from an older RenewalAttempt cannot recover a newer suspended episode.
    # Mutation caught: any paid occurrence for the Subscription reactivates its current suspended episode.
    test "success from a different occurrence cannot recover the current suspension" do
      old_occurrence = create_bound_occurrence!("jc240_different_occurrence")
      mark_collection_successful!(old_occurrence.collection, db_now!())

      {:ok, old_handoff} =
        RenewalCollectionAttempts.success_handoff_for_system(old_occurrence.collection.id)

      assert {:ok, :reconciled} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 old_occurrence.order.id,
                 handoff_opts(old_handoff)
               )

      next_period_at = old_occurrence.attempt.period_end_at
      parent = self()
      calls = :atomics.new(1, [])
      stub_collection_requests!(parent, calls, ["canceled"])

      assert {:error, %{code: "PAYMENT_FAILED"}} =
               Facade.process_due_subscription_renewal_for_system(
                 old_occurrence.subscription.id,
                 now: next_period_at
               )

      new_attempt = fetch_current_attempt!(old_occurrence.subscription.id)
      assert new_attempt.id != old_occurrence.attempt.id
      assert new_attempt.renewal_key != old_occurrence.attempt.renewal_key
      assert :atomics.get(calls, 1) == 1
      assert length(drain_provider_requests()) == 1

      boundary_at = set_boundary_in_past!(old_occurrence.subscription.id, next_period_at)

      assert {:ok, %{suspended_count: 1}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      suspended = fetch_subscription!(old_occurrence.subscription.id)
      effects_before_replay = access_effect_rows!(old_occurrence.subscription.id)
      assert suspended.status == :suspended
      assert hd(effects_before_replay).disposition == "non_effective"

      _same_old_success_replay =
        mark_collection_successful!(old_occurrence.collection, db_now!())

      assert {:ok, :noop} =
               Facade.reconcile_paid_subscription_renewal_for_system(
                 old_occurrence.order.id,
                 handoff_opts(old_handoff)
               )

      unchanged = fetch_subscription!(old_occurrence.subscription.id)
      assert unchanged.status == :suspended
      assert unchanged.aggregate_version == suspended.aggregate_version
      assert access_effect_rows!(old_occurrence.subscription.id) == effects_before_replay

      refute Enum.any?(
               effects_before_replay,
               &(&1.status == "required" and &1.disposition == "effective")
             )
    end

    # Invariant: competing boundary runs serialize to one suspension version and one current non-effective target.
    # Mutation caught: allowing two transactions to commit a suspension or duplicate AccessEffect targets.
    test "competing boundary runs commit one suspension transition" do
      now = db_now!()

      %{subscription: subscription} =
        create_due_subscription!("jc240_boundary_race", now,
          max_retry_attempts: 0,
          retry_schedule_hours: [0],
          grace_period_days: 0
        )

      StripeAPIStub.stub_unexpected!("boundary suspension must not call a payment provider")

      assert {:ok, %{failed_count: 1}} =
               Facade.run_due_renewals_for_system(now: now, limit: 20)

      past_due = fetch_subscription!(subscription.id)
      boundary_at = past_due.failed_payment_boundary_at
      assert boundary_at == now
      parent = self()

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            send(parent, {:jc240_boundary_waiting, index, self()})

            receive do
              :jc240_run_boundary ->
                Facade.run_due_failed_payment_suspensions_for_system(
                  now: boundary_at,
                  limit: 20
                )
            after
              5_000 -> {:error, :boundary_barrier_timeout}
            end
          end)
        end

      waiting =
        for _ <- 1..2 do
          assert_receive {:jc240_boundary_waiting, index, pid}, 5_000
          {index, pid}
        end

      assert Enum.map(waiting, &elem(&1, 0)) |> Enum.sort() == [1, 2]
      Enum.each(waiting, fn {_index, pid} -> send(pid, :jc240_run_boundary) end)
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.sum(Enum.map(results, fn {:ok, result} -> result.suspended_count end)) == 1

      suspended = fetch_subscription!(subscription.id)
      assert suspended.status == :suspended
      assert suspended.aggregate_version == past_due.aggregate_version + 1
      [effect] = access_effect_rows!(subscription.id)
      assert effect.source_version == suspended.aggregate_version
      assert effect.disposition == "non_effective"

      assert {:ok, %{due_count: 0, suspended_count: 0, failed_count: 0}} =
               Facade.run_due_failed_payment_suspensions_for_system(now: boundary_at, limit: 20)

      assert fetch_subscription!(subscription.id).aggregate_version == suspended.aggregate_version
      assert access_effect_rows!(subscription.id) == [effect]
      assert provider_mutation_count() == 0
    end
  end

  defp create_bound_occurrence!(label) do
    now = db_now!()

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        now,
        [max_retry_attempts: 3, retry_schedule_hours: [0, 24, 72], grace_period_days: 7],
        %{provider_billing_ref: "pm_#{label}"}
      )

    parent = self()
    calls = :atomics.new(1, [])
    stub_collection_requests!(parent, calls, ["processing"])

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [request] = drain_provider_requests()
    assert :atomics.get(calls, 1) == 1
    attempt = fetch_current_attempt!(subscription.id)
    [collection] = list_collections!(attempt.id)
    assert collection.id == request.collection_id
    assert collection.dispatch_state == :may_have_been_reached

    %{
      now: now,
      subscription: subscription,
      attempt: attempt,
      order: fetch_order!(attempt.order_id),
      collection: collection
    }
  end

  defp create_failed_then_inflight_occurrence!(label, plan_overrides \\ []) do
    now = db_now!()

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        now,
        Keyword.merge(
          [max_retry_attempts: 3, retry_schedule_hours: [0, 24, 72], grace_period_days: 7],
          plan_overrides
        ),
        %{provider_billing_ref: "pm_#{label}"}
      )

    parent = self()
    calls = :atomics.new(1, [])
    stub_collection_requests!(parent, calls, ["canceled", "processing"])

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    first_failure = fetch_subscription!(subscription.id)
    assert first_failure.status == :past_due
    retry_at = first_failure.next_retry_at
    assert %DateTime{} = retry_at

    [first_request] = drain_provider_requests()
    assert first_request.number == 1
    assert first_request.dispatch_state == "may_have_been_reached"

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: retry_at)

    [retry_request] = drain_provider_requests()
    assert :atomics.get(calls, 1) == 2
    assert retry_request.number == 2
    assert first_request.collection_id != retry_request.collection_id

    attempt = fetch_current_attempt!(subscription.id)
    assert length(list_collections!(attempt.id)) == 2
    [failed_collection, inflight_collection] = list_collections!(attempt.id)
    assert failed_collection.dispatch_state == :may_have_been_reached
    assert failed_collection.id == first_request.collection_id
    assert inflight_collection.dispatch_state == :may_have_been_reached
    assert inflight_collection.financial_outcome == :unresolved
    assert inflight_collection.id == retry_request.collection_id

    %{
      now: now,
      subscription: subscription,
      attempt: attempt,
      order: fetch_order!(attempt.order_id),
      failed_collection: failed_collection,
      inflight_collection: inflight_collection
    }
  end

  defp mark_collection_successful!(collection, observed_at) do
    payment_intent = fetch_payment_intent!(collection.payment_intent_id)

    {provider_reference, provider_reference_kind} =
      if is_binary(payment_intent.provider_payment_id) do
        {payment_intent.provider_payment_id, :payment_intent}
      else
        {payment_intent.provider_request_reference, :transaction_reference}
      end

    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: provider_reference,
      provider_reference_kind: provider_reference_kind,
      provider_transaction_id: payment_intent.provider_payment_id || "pi_#{payment_intent.id}",
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: observed_at
    }

    assert {:ok, %{outcome: outcome}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert outcome in [:authoritative_success, :already_applied_success]
    updated_collection = fetch_collection!(collection.id)

    assert :ok ==
             Store.Payments.validate_collection_outcome_certification_for_system(
               %ValidateRenewalCollectionOutcomeInput{
                 payment_attempt_id: updated_collection.payment_attempt_id,
                 payment_intent_id: collection.payment_intent_id,
                 financial_outcome: :verified_success
               }
             )
  end

  defp record_failure_observation!(payment_intent, observed_at) do
    observation = %ProviderObservation{
      provider: payment_intent.provider,
      provider_reference: payment_intent.provider_payment_id,
      provider_reference_kind: :payment_intent,
      provider_transaction_id: payment_intent.provider_payment_id,
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :failure_observation,
      raw_provider_status: "canceled",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: observed_at
    }

    Store.Payments.record_and_apply_payment_observation_for_system(payment_intent, observation)
  end

  defp mark_past_due!(subscription_id, attrs) do
    subscription = fetch_subscription!(subscription_id)

    subscription
    |> Ash.Changeset.for_update(:mark_past_due_transition, attrs, context: @system_context)
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp set_boundary_in_past!(subscription_id, _business_now) do
    boundary_at = DateTime.add(db_now!(), -1, :second)
    past_due_since_at = DateTime.add(boundary_at, -7, :day)
    retry_suppressed_at = db_now!()

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', dunning_attempt_count = 1, past_due_since_at = $2, failed_payment_boundary_at = $3, next_retry_at = NULL, retry_suppressed_at = $4 WHERE id = $1",
      [
        Ecto.UUID.dump!(subscription_id),
        past_due_since_at,
        boundary_at,
        retry_suppressed_at
      ]
    )

    boundary_at
  end

  defp access_effect_rows!(subscription_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT source_version, status::text, disposition::text, valid_from_at, valid_until_at FROM access_effects WHERE subscription_id = $1 ORDER BY source_version DESC",
        [Ecto.UUID.dump!(subscription_id)]
      )

    Enum.map(rows, fn [source_version, status, disposition, valid_from_at, valid_until_at] ->
      %{
        source_version: source_version,
        status: status,
        disposition: disposition,
        valid_from_at: valid_from_at,
        valid_until_at: valid_until_at
      }
    end)
  end

  defp email_outbox_count(subscription_id) do
    EmailOutbox
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Comms, authorize?: false, context: @system_context)
  end

  defp provider_mutation_count, do: length(drain_provider_requests())

  defp handoff_opts(handoff) do
    [
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    ]
  end

  defp create_due_subscription!(label, now, plan_overrides, subscription_overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(
        Map.merge(
          %{
            interval_unit: :day,
            interval_count: 1,
            retry_schedule_hours: [0, 24, 72],
            max_retry_attempts: 3,
            grace_period_days: 7,
            entitlement_kind: :membership_access,
            entitlement_scope_key: "membership:#{label}"
          },
          Map.new(plan_overrides)
        )
      )

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    started_at = DateTime.add(now, -86_400, :second)

    fixture_overrides =
      Map.merge(
        %{started_at: started_at, next_renewal_at: DateTime.add(now, -1, :microsecond)},
        subscription_overrides
      )

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(
        customer.id,
        variant,
        plan,
        fixture_overrides
      )

    %{subscription: subscription, customer: customer, variant: variant, plan: plan}
  end

  defp due_retry?(subscription_id, now) do
    assert {:ok, jobs} = Facade.list_due_renewal_jobs_for_system(now: now, limit: 100)
    Enum.any?(jobs, &(&1.subscription_id == subscription_id))
  end

  defp assert_boundary_retry_denied!(label, offset_microseconds) do
    origin = DateTime.add(db_now!(), -30 * 86_400, :second)

    %{subscription: subscription} =
      create_due_subscription!(
        label,
        origin,
        [max_retry_attempts: 1, retry_schedule_hours: [0], grace_period_days: 0],
        %{provider_billing_ref: "pm_#{label}"}
      )

    parent = self()
    calls = :atomics.new(1, [])
    stub_collection_requests!(parent, calls, ["canceled", "processing"])

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: origin)

    failed = fetch_subscription!(subscription.id)
    original_boundary_at = failed.failed_payment_boundary_at
    retry_at = failed.next_retry_at
    assert retry_at == original_boundary_at
    assert failed.retry_suppressed_at == nil
    assert :atomics.get(calls, 1) == 1

    [first_request] = drain_provider_requests()
    assert first_request.number == 1
    assert first_request.dispatch_state == "may_have_been_reached"

    attempt = fetch_current_attempt!(subscription.id)
    order = fetch_order!(attempt.order_id)
    retry_collection = start_retry_collection!(attempt, retry_at)
    retry_intent = create_collection_payment_intent!(retry_collection, order, attempt)

    assert {:ok, %{collection_attempt: bound_collection}} =
             RenewalCollectionAttempts.attach_payment_intent_for_system(
               %PaymentIntentBindingInput{
                 collection_attempt_id: retry_collection.id,
                 payment_intent_id: retry_intent.id
               }
             )

    assert bound_collection.dispatch_state == :not_started

    retry_now = DateTime.add(retry_at, offset_microseconds, :microsecond)
    assert due_retry?(subscription.id, retry_now)

    boundary_at = persist_boundary_at_claim_seam!(subscription.id, offset_microseconds)
    assert DateTime.compare(retry_now, boundary_at) == :lt

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: retry_now)

    assert :atomics.get(calls, 1) == 1
    assert drain_provider_requests() == []

    [first_collection, denied_collection] = list_collections!(attempt.id)
    assert first_collection.dispatch_state == :may_have_been_reached
    assert denied_collection.id == retry_collection.id
    assert denied_collection.payment_intent_id == retry_intent.id
    assert denied_collection.dispatch_state == :not_submitted

    assert fetch_subscription!(subscription.id).failed_payment_boundary_at == boundary_at
    assert length(list_collections!(attempt.id)) == 2
  end

  defp start_retry_collection!(attempt, now) do
    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: attempt.id,
               now: now
             })

    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    collection
  end

  defp create_collection_payment_intent!(collection, order, attempt) do
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, provider_request_reference} =
             Providers.renewal_collection_request_reference(subscription.provider, collection.id)

    assert {:ok, result} =
             Store.Payments.create_or_reuse_payment_intent(
               %{
                 order_id: order.id,
                 amount_received_minor: order.grand_total_minor,
                 currency: attempt.currency,
                 provider: subscription.provider,
                 payment_intent_key: RenewalCollectionAttempts.payment_intent_key(collection.id),
                 provider_request_reference: provider_request_reference
               },
               context: @system_context
             )

    result.payment_intent
  end

  defp persist_boundary_at_claim_seam!(subscription_id, 0) do
    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )

    fetch_subscription!(subscription_id).failed_payment_boundary_at
  end

  defp persist_boundary_at_claim_seam!(subscription_id, 1) do
    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 microsecond' WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )

    fetch_subscription!(subscription_id).failed_payment_boundary_at
  end

  defp stub_collection_requests!(parent, calls, statuses) do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      number = :atomics.add_get(calls, 1, 1)
      collection_id = Map.fetch!(params, "metadata[collection_attempt_id]")
      renewal_attempt_id = Map.fetch!(params, "metadata[renewal_attempt_id]")
      [idempotency_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

      %{rows: [[dispatch_state]]} =
        Repo.query!(
          "SELECT dispatch_state::text FROM renewal_collection_attempts WHERE id = $1::uuid",
          [Ecto.UUID.dump!(collection_id)]
        )

      send(parent, {
        :jc240_provider_mutation,
        %{
          number: number,
          collection_id: collection_id,
          renewal_attempt_id: renewal_attempt_id,
          idempotency_key: idempotency_key,
          dispatch_state: dispatch_state
        }
      })

      status = Enum.at(statuses, number - 1, "processing")

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => status})
      )
    end)
  end

  defp drain_provider_requests(acc \\ []) do
    receive do
      {:jc240_provider_mutation, request} -> drain_provider_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp due_boundary_ids(now) do
    Subscription
    |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{now: now, limit: 100})
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.map(& &1.id)
  end

  defp db_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp fetch_current_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp list_collections!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
    |> Enum.sort_by(& &1.collection_ordinal)
  end

  defp fetch_payment_intent!(id) do
    PaymentIntent
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Payments, authorize?: false, context: @system_context)
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: @system_context)
  end

  defp fetch_order!(id) do
    Order
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Orders, authorize?: false, context: @system_context)
  end

  defp unique_label(label), do: "#{label}_#{System.unique_integer([:positive])}"
end
