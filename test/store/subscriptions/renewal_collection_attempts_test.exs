defmodule Store.Subscriptions.RenewalCollectionAttemptsTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Repo

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Scheduler,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.StartInput
  alias Store.SubscriptionsFixtures

  test "start input accepts a UUID and an explicit current time" do
    renewal_attempt_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: renewal_attempt_id,
               now: now
             })

    assert input.renewal_attempt_id == renewal_attempt_id
    assert input.now == now
  end

  test "start input rejects untyped or incomplete data" do
    assert {:error, error} = StartInput.new(%{renewal_attempt_id: "bad", now: DateTime.utc_now()})
    assert error.code == "VALIDATION_ERROR"

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(%{})
    assert error.code == "VALIDATION_ERROR"
  end

  test "collection payment intent key is bound to the collection identity" do
    collection_attempt_id = Ecto.UUID.generate()

    assert RenewalCollectionAttempts.payment_intent_key(collection_attempt_id) ==
             "renewal-collection:" <> collection_attempt_id
  end

  test "first start creates ordinal one and active replay returns that exact collection" do
    {attempt, now} = create_bound_attempt!("jc229_collection_start_replay")
    input = start_input!(attempt.id, now)

    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)
    assert first.collection_ordinal == 1
    assert first.financial_outcome == :unresolved
    assert first.dispatch_state == :not_started

    assert {:ok, replay} = RenewalCollectionAttempts.start_for_system(input)
    assert replay.id == first.id
    assert replay.renewal_attempt_id == first.renewal_attempt_id
    assert replay.collection_ordinal == first.collection_ordinal
  end

  test "concurrent starts return one active collection identity" do
    {attempt, now} = create_bound_attempt!("jc229_collection_concurrent_start")
    input = start_input!(attempt.id, now)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:start_waiting, self()})

          receive do
            :start_collection -> RenewalCollectionAttempts.start_for_system(input)
          after
            5_000 -> {:error, :start_barrier_timeout}
          end
        end)
      end

    task_pids =
      for _ <- 1..2 do
        assert_receive {:start_waiting, task_pid}, 5_000
        task_pid
      end

    Enum.each(task_pids, &send(&1, :start_collection))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert [{:ok, first}, {:ok, second}] = Enum.sort_by(results, fn {:ok, item} -> item.id end)
    assert first.id == second.id
    assert first.collection_ordinal == 1
    assert [only_collection] = list_collections!(attempt.id)
    assert only_collection.id == first.id
  end

  test "an incomplete renewal contract fails before collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_incomplete_contract")
    unbound_attempt = create_unbound_attempt!(attempt)

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(unbound_attempt.id, now))

    assert error.code == "VALIDATION_ERROR"
    assert [] == list_collections!(unbound_attempt.id)
  end

  test "a legacy PaymentIntent without collection identity fails closed" do
    {attempt, now} = create_bound_attempt!("jc229_collection_legacy_pi")
    subscription = fetch_subscription!(attempt.subscription_id)
    legacy_payment_intent = create_legacy_payment_intent!(subscription)

    assert {:ok, _processing} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_processing,
               %{
                 order_id: subscription.source_order_id,
                 payment_intent_id: legacy_payment_intent.id
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "PAYMENT_EVENT_UNVERIFIED"
    assert [] == list_collections!(attempt.id)
    assert fetch_renewal_attempt!(attempt.id).payment_intent_id == legacy_payment_intent.id
  end

  test "a legacy succeeded RenewalAttempt without collection identity fails closed" do
    {attempt, now} = create_bound_attempt!("jc229_collection_legacy_succeeded")
    subscription = fetch_subscription!(attempt.subscription_id)
    legacy_payment_intent = create_legacy_payment_intent!(subscription)

    assert {:ok, _succeeded} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_succeeded,
               %{
                 order_id: subscription.source_order_id,
                 payment_intent_id: legacy_payment_intent.id
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "PAYMENT_EVENT_UNVERIFIED"
    assert [] == list_collections!(attempt.id)
  end

  test "requires_action remains the active collection and does not allocate an ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_requires_action")
    input = start_input!(attempt.id, now)
    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    set_financial_outcome!(collection, attempt.subscription_id, :requires_action)

    assert {:ok, replay} = RenewalCollectionAttempts.start_for_system(input)
    assert replay.id == collection.id

    assert [only_collection] = list_collections!(attempt.id)

    assert only_collection.id == collection.id
  end

  test "verified success permanently closes collection allocation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_success_closes")
    input = start_input!(attempt.id, now)
    assert {:ok, collection} = RenewalCollectionAttempts.start_for_system(input)
    set_financial_outcome!(collection, attempt.subscription_id, :verified_success)

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"
  end

  test "certified terminal non-success permits the next contiguous ordinal when retry is due" do
    {attempt, now} = create_bound_attempt!("jc229_collection_next_ordinal")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second))

    assert {:ok, second} = RenewalCollectionAttempts.start_for_system(input)
    assert second.collection_ordinal == 2
    assert second.id != first.id
  end

  test "certified terminal non-success does not permit a collection before retry time" do
    {attempt, now} = create_bound_attempt!("jc229_collection_retry_not_due")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, 60, :second))

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"

    assert [only_collection] = list_collections!(attempt.id)

    assert only_collection.id == first.id
  end

  test "dunning limit from the bound contract blocks another ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_retry_exhausted")
    input = start_input!(attempt.id, now)
    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)

    set_financial_outcome!(
      first,
      attempt.subscription_id,
      :verified_terminal_financial_non_success
    )

    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second), 4)

    assert {:error, error} = RenewalCollectionAttempts.start_for_system(input)
    assert error.code == "INVALID_STATE_TRANSITION"
    assert [only_collection] = list_collections!(attempt.id)
    assert only_collection.id == first.id
  end

  test "scheduled cancellation blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_cancel_scheduled")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _updated} =
             subscription
             |> Ash.Changeset.for_update(:cancel_at_period_end_transition, %{},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "immediate cancellation blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_cancel_now")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _canceled} =
             subscription
             |> Ash.Changeset.for_update(:cancel_now_transition, %{canceled_reason: "customer"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "expired subscription blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_expired")
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _expired} =
             subscription
             |> Ash.Changeset.for_update(:mark_expired_transition, %{canceled_reason: "term_end"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "withdrawn RenewalAttempt authority blocks collection creation" do
    {attempt, now} = create_bound_attempt!("jc229_collection_withdrawn_attempt")

    assert {:ok, _withdrawn} =
             attempt
             |> Ash.Changeset.for_update(
               :mark_authority_withdrawn,
               %{failure_message: "authority withdrawn"},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  test "suspension blocks a new collection ordinal" do
    {attempt, now} = create_bound_attempt!("jc229_collection_suspended")
    mark_past_due!(attempt.subscription_id, now, DateTime.add(now, -1, :second))
    subscription = fetch_subscription!(attempt.subscription_id)

    assert {:ok, _suspended} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_suspended_transition,
               %{
                 billing_status_reason: "RETRY_EXHAUSTED",
                 past_due_since_at: now,
                 dunning_attempt_count: 1
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             RenewalCollectionAttempts.start_for_system(start_input!(attempt.id, now))

    assert error.code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == list_collections!(attempt.id)
  end

  defp start_input!(renewal_attempt_id, now) do
    assert {:ok, input} =
             StartInput.new(%{
               renewal_attempt_id: renewal_attempt_id,
               now: now
             })

    input
  end

  defp create_bound_attempt!(label) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    customer =
      SubscriptionsFixtures.create_customer!("#{label}_#{System.unique_integer([:positive])}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second),
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    period = Scheduler.next_period(subscription.current_period_end_at, revision)

    attrs = %{
      subscription_id: subscription.id,
      period_start_at: subscription.current_period_end_at,
      period_end_at: period.current_period_end_at,
      renewal_key: Scheduler.renewal_key(subscription.id, period.current_period_end_at),
      plan_revision_id: revision.id,
      variant_id: variant.id,
      quantity: subscription.quantity,
      amount_minor: plan.amount_minor,
      currency: plan.currency,
      expected_subscription_version: subscription.aggregate_version,
      charged_contract_version: 1,
      charged_contract_snapshot: charged_contract_snapshot(revision, plan),
      status: :pending
    }

    attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {attempt, now}
  end

  defp create_unbound_attempt!(attempt) do
    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: attempt.subscription_id,
        period_start_at: attempt.period_start_at,
        period_end_at: attempt.period_end_at,
        renewal_key: attempt.renewal_key <> ":unbound",
        status: :pending
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp set_financial_outcome!(collection, subscription_id, outcome) do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          amount_received_minor: 0,
          currency: "USD",
          provider: :stripe,
          subscription_id: subscription_id,
          payment_intent_key: "jc229_collection_test:#{Ecto.UUID.generate()}"
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE renewal_collection_attempts SET payment_intent_id = $1::uuid, financial_outcome = $2 WHERE id = $3::uuid",
               [uuid_param(payment_intent.id), Atom.to_string(outcome), uuid_param(collection.id)]
             )
  end

  defp create_legacy_payment_intent!(subscription) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        order_id: subscription.source_order_id,
        amount_received_minor: 0,
        currency: "USD",
        provider: :stripe,
        subscription_id: subscription.id,
        payment_intent_key: "jc229_legacy_pi:#{Ecto.UUID.generate()}"
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp mark_past_due!(subscription_id, now, next_retry_at, count \\ 1) do
    subscription = fetch_subscription!(subscription_id)

    assert {:ok, _updated} =
             subscription
             |> Ash.Changeset.for_update(
               :mark_past_due_transition,
               %{
                 billing_status_reason: "PAYMENT_FAILED",
                 past_due_since_at: now,
                 dunning_attempt_count: count,
                 next_retry_at: next_retry_at,
                 retry_suppressed_at: nil
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_renewal_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp list_collections!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.for_read(:read_for_renewal_attempt, %{renewal_attempt_id: renewal_attempt_id})
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp uuid_param(uuid) do
    {:ok, binary} = Ecto.UUID.dump(uuid)
    binary
  end

  defp charged_contract_snapshot(revision, plan) do
    %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => snapshot_datetime(revision.term_end_at),
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => snapshot_enum(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }
  end

  defp snapshot_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp snapshot_datetime(_value), do: nil
  defp snapshot_enum(nil), do: nil
  defp snapshot_enum(value) when is_atom(value), do: Atom.to_string(value)
end
