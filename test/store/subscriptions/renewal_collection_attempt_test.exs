defmodule Store.Subscriptions.RenewalCollectionAttemptTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{Facade, RenewalAttempt, RenewalCollectionAttempt}
  alias Store.Orders.InventoryReservation
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "a new collection has independent dispatch and financial state" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_defaults")
    collection = create_collection!(attempt.id, 1)

    assert collection.renewal_attempt_id == attempt.id
    assert collection.collection_ordinal == 1
    assert collection.dispatch_state == :not_started
    assert collection.financial_outcome == :unresolved
    assert collection.dispatch_epoch == 1
    assert collection.fenced_through_epoch == 0
    assert is_nil(collection.payment_intent_id)
  end

  test "the database rejects a nonpositive ordinal" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_bad_ordinal")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET collection_ordinal = 0 WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database rejects an unknown dispatch state" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_bad_dispatch")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET dispatch_state = 'unknown' WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database rejects an unknown financial outcome" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_bad_outcome")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET financial_outcome = 'failed' WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database rejects an epoch that skips its fence" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_bad_epoch")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET dispatch_epoch = 2 WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database rejects not_submitted without exact fence evidence" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_unfenced_not_submitted")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET dispatch_state = 'not_submitted' WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database requires complete fence evidence" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_bad_fence")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET last_fence_event_id = uuid_generate_v7() WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "the database requires a payment intent for a resolved financial outcome" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_no_intent")
    collection = create_collection!(attempt.id, 1)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET financial_outcome = 'verified_success' WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "only one active collection is allowed per renewal attempt" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_one_active")
    _collection = create_collection!(attempt.id, 1)

    assert_unique_violation(raw_insert_collection(attempt.id, 2, :unresolved, nil))
  end

  test "a payment intent belongs to at most one collection" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_one_intent")
    payment_intent_id = attempt.payment_intent_id

    assert is_binary(payment_intent_id)

    assert {:ok, _} =
             raw_insert_collection(
               attempt.id,
               1,
               :verified_terminal_financial_non_success,
               payment_intent_id
             )

    assert_unique_violation(raw_insert_collection(attempt.id, 2, :unresolved, payment_intent_id))
  end

  test "a bound payment intent cannot be replaced or detached" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_intent_immutable")
    collection = create_collection!(attempt.id, 1)

    assert {:ok, _} =
             Store.Repo.query(
               "UPDATE renewal_collection_attempts SET payment_intent_id = $1::uuid WHERE id = $2::uuid",
               [uuid_param(attempt.payment_intent_id), uuid_param(collection.id)]
             )

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET payment_intent_id = NULL WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "a bound reservation generation cannot be detached" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_reservation_immutable")
    collection = create_collection!(attempt.id, 1)
    generation_id = create_reservation_generation!(attempt)

    assert {:ok, _} =
             Store.Repo.query(
               "UPDATE renewal_collection_attempts SET reservation_generation_id = $1::uuid WHERE id = $2::uuid",
               [uuid_param(generation_id), uuid_param(collection.id)]
             )

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET reservation_generation_id = NULL WHERE id = $1::uuid",
      [uuid_param(collection.id)]
    )
  end

  test "a bound reservation generation cannot be replaced outside fenced resume" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_reservation_replace")
    collection = create_collection!(attempt.id, 1)
    first_generation_id = create_reservation_generation!(attempt)
    second_generation_id = create_reservation_generation!(attempt)

    assert {:ok, _} =
             Store.Repo.query(
               "UPDATE renewal_collection_attempts SET reservation_generation_id = $1::uuid WHERE id = $2::uuid",
               [uuid_param(first_generation_id), uuid_param(collection.id)]
             )

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET reservation_generation_id = $1::uuid WHERE id = $2::uuid",
      [uuid_param(second_generation_id), uuid_param(collection.id)]
    )
  end

  test "fenced resume can replace the exact reservation generation without a new collection" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_reservation_resume")
    collection = create_collection!(attempt.id, 1)
    first_generation_id = create_reservation_generation!(attempt)
    next_generation_id = create_reservation_generation!(attempt)

    assert {:ok, _} =
             Store.Repo.query(
               "UPDATE renewal_collection_attempts SET reservation_generation_id = $1::uuid WHERE id = $2::uuid",
               [uuid_param(first_generation_id), uuid_param(collection.id)]
             )

    assert {:ok, _} =
             Store.Repo.query(
               """
               UPDATE renewal_collection_attempts
               SET dispatch_state = 'not_submitted',
                   fenced_through_epoch = 1,
                   last_fence_event_id = uuid_generate_v7(),
                   last_fenced_at = now()
               WHERE id = $1::uuid
               """,
               [uuid_param(collection.id)]
             )

    assert {:ok, _} =
             Store.Repo.query(
               """
               UPDATE renewal_collection_attempts
               SET dispatch_state = 'not_started',
                   dispatch_epoch = 2,
                   reservation_generation_id = $1::uuid
               WHERE id = $2::uuid
               """,
               [uuid_param(next_generation_id), uuid_param(collection.id)]
             )
  end

  test "verified success prevents another collection ordinal at the database boundary" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_success_closes")
    payment_intent_id = attempt.payment_intent_id

    assert is_binary(payment_intent_id)

    assert {:ok, _} =
             raw_insert_collection(attempt.id, 1, :verified_success, payment_intent_id)

    assert_closed_renewal(raw_insert_collection(attempt.id, 2, :unresolved, nil))
  end

  test "the database rejects a noncontiguous collection ordinal" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_ordinal_gap")
    _collection = create_collection!(attempt.id, 1)

    assert_check_violation(raw_insert_collection(attempt.id, 3, :unresolved, nil))
  end

  test "success cannot be recorded after a later collection ordinal exists" do
    {attempt, _now} = create_bound_attempt!("jc229_collection_success_after_later")
    payment_intent_id = attempt.payment_intent_id

    assert {:ok, _} =
             raw_insert_collection(
               attempt.id,
               1,
               :verified_terminal_financial_non_success,
               payment_intent_id
             )

    _later_collection = create_collection!(attempt.id, 2)

    assert_check_violation(
      "UPDATE renewal_collection_attempts SET financial_outcome = 'verified_success' WHERE renewal_attempt_id = $1::uuid AND collection_ordinal = 1",
      [uuid_param(attempt.id)]
    )
  end

  defp create_bound_attempt!(label) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    customer =
      SubscriptionsFixtures.create_customer!("#{label}_#{System.unique_integer([:positive])}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -10, :second),
        provider_billing_ref: "pm_#{label}"
      })

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    {attempt, now}
  end

  defp create_collection!(renewal_attempt_id, ordinal) do
    RenewalCollectionAttempt
    |> Ash.Changeset.for_create(
      :create,
      %{renewal_attempt_id: renewal_attempt_id, collection_ordinal: ordinal},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_reservation_generation!(attempt) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    InventoryReservation
    |> Ash.Changeset.for_create(
      :create,
      %{
        order_id: attempt.order_id,
        variant_id: attempt.variant_id,
        reservation_key: "jc229-test-generation:#{Ecto.UUID.generate()}",
        quantity: attempt.quantity || 1,
        state: :cancelled,
        expires_at: DateTime.add(now, 60, :second),
        cancelled_at: now
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> Map.fetch!(:id)
  end

  defp raw_insert_collection(renewal_attempt_id, ordinal, outcome, payment_intent_id) do
    id = Store.Repo.query!("SELECT uuid_generate_v7()::text").rows |> hd() |> hd()

    Store.Repo.query(
      """
      INSERT INTO renewal_collection_attempts (
        id, renewal_attempt_id, collection_ordinal, dispatch_state,
        financial_outcome, payment_intent_id, dispatch_epoch,
        fenced_through_epoch, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2::uuid, $3, 'not_started', $4, $5::uuid,
        1, 0, now(), now()
      )
      """,
      [
        uuid_param(id),
        uuid_param(renewal_attempt_id),
        ordinal,
        Atom.to_string(outcome),
        if(payment_intent_id, do: uuid_param(payment_intent_id), else: nil)
      ]
    )
  end

  defp assert_check_violation(sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Store.Repo.query(sql, params)
  end

  defp assert_check_violation({:error, %Postgrex.Error{postgres: %{code: :check_violation}}}),
    do: :ok

  defp assert_check_violation(result),
    do: flunk("expected check violation, got: #{inspect(result)}")

  defp assert_unique_violation({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}),
    do: :ok

  defp assert_unique_violation(result),
    do: flunk("expected unique violation, got: #{inspect(result)}")

  defp assert_closed_renewal({:error, %Postgrex.Error{postgres: %{code: :check_violation}}}),
    do: :ok

  defp assert_closed_renewal(result),
    do: flunk("expected closed renewal rejection, got: #{inspect(result)}")

  defp uuid_param(value), do: Ecto.UUID.dump!(value)
end
