defmodule Store.Subscriptions.RenewalCollectionAttemptTest do
  use Store.DataCase, async: false

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Orders.InventoryReservation
  alias Store.Payments.PaymentIntent

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Scheduler,
    Subscription
  }

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    AttachPaymentIntentInput,
    DispatchInput,
    FenceInput,
    RefreshFinancialOutcomeInput,
    ReservationGenerationInput,
    ResumeInput,
    StartInput
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "creates ordinal one and replays the active collection identity" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    input = %StartInput{renewal_attempt_id: attempt.id}

    assert {:ok, first} = RenewalCollectionAttempts.start_for_system(input)
    assert {:ok, replay} = RenewalCollectionAttempts.start_for_system(input)

    assert first.id == replay.id
    assert first.renewal_attempt_id == attempt.id
    assert first.collection_ordinal == 1
    assert first.dispatch_state == :not_started
    assert first.financial_outcome == :unresolved
    assert first.dispatch_epoch == 1
    assert first.fenced_through_epoch == 0
    assert is_nil(first.payment_intent_id)
    assert attempt.attempt_no == 1

    assert RenewalCollectionAttempts.payment_intent_key(first.id) ==
             "renewal-collection:#{first.id}"

    assert collection_count(attempt.id) == 1
  end

  test "not_submitted still occupies the unresolved collection slot" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    first = start_collection!(attempt)

    assert {:ok, fenced} =
             RenewalCollectionAttempts.fence_before_submission_for_system(%FenceInput{
               collection_attempt_id: first.id,
               expected_dispatch_epoch: 1,
               fence_event_id: Ash.UUIDv7.generate()
             })

    assert fenced.dispatch_state == :not_submitted
    assert fenced.financial_outcome == :unresolved
    assert fenced.fenced_through_epoch == 1

    assert {:ok, replay} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id
             })

    assert replay.id == first.id
    assert collection_count(attempt.id) == 1
  end

  test "concurrent first collection calls serialize at the database" do
    fixture = create_committed_fixture!()
    attempt = Sandbox.unboxed_run(Store.Repo, fn -> renewal_attempt!(fixture) end)
    parent = self()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    tasks =
      Enum.map([:one, :two], fn label ->
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")
            send(parent, {:ready, label, backend_pid})

            receive do
              :start ->
                RenewalCollectionAttempts.start_for_system(%StartInput{
                  renewal_attempt_id: attempt.id,
                  now: now
                })
            after
              10_000 -> flunk("timed out waiting to start concurrent collection creation")
            end
          end)
        end)
      end)

    ready =
      for _ <- tasks,
          do:
            (receive do
               {:ready, _label, backend_pid} -> backend_pid
             after
               10_000 -> flunk("timed out waiting for independent collection connections")
             end)

    assert length(Enum.uniq(ready)) == 2
    Enum.each(tasks, &send(&1.pid, :start))
    [first, second] = Enum.map(tasks, &Task.await(&1, 10_000))

    assert {:ok, first_collection} = first
    assert {:ok, second_collection} = second
    assert first_collection.id == second_collection.id

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Sandbox.unboxed_run(Store.Repo, fn ->
               Repo.query(
                 """
                 INSERT INTO renewal_collection_attempts
                   (renewal_attempt_id, collection_ordinal, dispatch_state,
                    financial_outcome, dispatch_epoch, fenced_through_epoch)
                 VALUES ($1, 2, 'not_started', 'unresolved', 1, 0)
                 """,
                 [Ecto.UUID.dump!(attempt.id)]
               )
             end)

    assert Sandbox.unboxed_run(Store.Repo, fn -> collection_count(attempt.id) end) == 1
  end

  test "an unresolved or requires_action collection blocks another ordinal" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    first = start_collection!(attempt)

    assert {:ok, same} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id
             })

    assert same.id == first.id
    assert collection_count(attempt.id) == 1

    intent = create_payment_intent!(attempt, first)
    assert {:ok, _} = attach_payment_intent(first, intent)
    assert {:ok, _} = claim(first)
    intent = payment_intent_transition!(intent, :submit)
    _intent = payment_intent_transition!(intent, :mark_requires_action)

    assert {:ok, requires_action} =
             RenewalCollectionAttempts.refresh_financial_outcome_for_system(
               %RefreshFinancialOutcomeInput{collection_attempt_id: first.id}
             )

    assert requires_action.financial_outcome == :requires_action

    assert {:error, _} =
             requires_action
             |> Ash.Changeset.for_update(
               :record_financial_outcome,
               %{
                 expected_financial_outcome: :requires_action,
                 financial_outcome: :unresolved
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, same_requires_action} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id
             })

    assert same_requires_action.id == first.id
    assert collection_count(attempt.id) == 1
  end

  test "verified terminal non-success permits a later ordinal only when dunning is due" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    first = start_collection!(attempt)
    intent = create_payment_intent!(attempt, first)
    assert {:ok, _} = attach_payment_intent(first, intent)
    assert {:ok, _} = claim(first)
    intent = payment_intent_transition!(intent, :submit)
    _intent = payment_intent_transition!(intent, :mark_failed)

    assert {:ok, failed} =
             RenewalCollectionAttempts.refresh_financial_outcome_for_system(
               %RefreshFinancialOutcomeInput{collection_attempt_id: first.id}
             )

    assert failed.financial_outcome == :verified_terminal_financial_non_success

    for outcome <- [:unresolved, :requires_action] do
      assert {:error, _} =
               failed
               |> Ash.Changeset.for_update(
                 :record_financial_outcome,
                 %{
                   expected_financial_outcome: :verified_terminal_financial_non_success,
                   financial_outcome: outcome
                 },
                 context: %{system?: true}
               )
               |> Ash.update(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: %{system?: true}
               )
    end

    future_retry = DateTime.add(DateTime.utc_now(), 3_600, :second)
    past_due = set_past_due!(fixture.subscription, future_retry)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id,
               now: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             })

    due_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    maximum = attempt.charged_contract_snapshot["max_retry_attempts"]
    assert maximum > 0

    at_retry_limit =
      set_past_due!(
        reload_subscription!(past_due.id),
        DateTime.add(due_now, -1, :second),
        maximum
      )

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id,
               now: due_now
             })

    set_past_due!(
      reload_subscription!(at_retry_limit.id),
      DateTime.add(due_now, -1, :second),
      maximum - 1
    )

    assert {:ok, second} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id,
               now: due_now
             })

    assert second.collection_ordinal == 2
    assert second.id != first.id
    assert second.financial_outcome == :unresolved
    assert attempt.attempt_no == 1

    assert RenewalCollectionAttempts.payment_intent_key(second.id) !=
             RenewalCollectionAttempts.payment_intent_key(first.id)

    assert collection_count(attempt.id) == 2
  end

  test "verified success permanently rejects later collection creation" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    first = start_collection!(attempt)
    intent = create_payment_intent!(attempt, first)
    assert {:ok, _} = attach_payment_intent(first, intent)
    assert {:ok, _} = claim(first)
    intent = payment_intent_transition!(intent, :submit)
    _intent = payment_intent_transition!(intent, :mark_succeeded)

    assert {:ok, succeeded} =
             RenewalCollectionAttempts.refresh_financial_outcome_for_system(
               %RefreshFinancialOutcomeInput{collection_attempt_id: first.id}
             )

    assert succeeded.financial_outcome == :verified_success

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id
             })

    assert collection_count(attempt.id) == 1
  end

  test "dispatch claim commits may_have_been_reached and rejects stale epochs" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    collection = start_collection!(attempt)
    intent = create_payment_intent!(attempt, collection)
    assert {:ok, _} = attach_payment_intent(collection, intent)

    assert {:ok, claimed} = claim(collection)
    assert claimed.dispatch_state == :may_have_been_reached
    assert claimed.dispatch_epoch == 1

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} = claim(collection)

    assert {:error, %Error{code: "STALE_RECORD"}} =
             RenewalCollectionAttempts.claim_dispatch_for_system(%DispatchInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 2
             })

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.fence_before_submission_for_system(%FenceInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 1,
               fence_event_id: Ash.UUIDv7.generate()
             })
  end

  test "pre-submission fence releases only the exact generation and resume increments once" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    collection = start_collection!(attempt)
    generation_id = Ash.UUIDv7.generate()
    reservation_key = reservation_key(attempt, collection, generation_id)

    assert {:ok, %{reservation: %{state: :active}}} =
             Store.Orders.reserve_exact_generation(
               attempt.order_id,
               attempt.variant_id,
               reservation_key,
               attempt.quantity
             )

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               %ReservationGenerationInput{
                 collection_attempt_id: collection.id,
                 expected_dispatch_epoch: 1,
                 reservation_generation_id: generation_id
               }
             )

    assert assigned.reservation_generation_id == generation_id

    fence = %FenceInput{
      collection_attempt_id: collection.id,
      expected_dispatch_epoch: 1,
      fence_event_id: Ash.UUIDv7.generate()
    }

    assert {:ok, fenced} = RenewalCollectionAttempts.fence_before_submission_for_system(fence)
    assert fenced.dispatch_state == :not_submitted
    assert fenced.financial_outcome == :unresolved
    assert fenced.fenced_through_epoch == 1
    assert fenced.reservation_generation_id == generation_id
    assert fenced.last_fence_event_id == fence.fence_event_id
    assert fenced.last_fenced_at

    assert {:ok, replayed_fence} =
             RenewalCollectionAttempts.fence_before_submission_for_system(fence)

    assert replayed_fence.id == fenced.id

    next_generation_id = Ash.UUIDv7.generate()
    next_reservation_key = reservation_key(attempt, collection, next_generation_id)

    assert {:ok, %{reservation: %{state: :active}}} =
             Store.Orders.reserve_exact_generation(
               attempt.order_id,
               attempt.variant_id,
               next_reservation_key,
               attempt.quantity
             )

    assert {:ok, resumed} =
             RenewalCollectionAttempts.resume_after_fence_for_system(%ResumeInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 1,
               reservation_generation_id: next_generation_id
             })

    assert resumed.dispatch_epoch == 2
    assert resumed.fenced_through_epoch == 1
    assert resumed.dispatch_state == :not_started
    assert resumed.reservation_generation_id != generation_id
    assert resumed.financial_outcome == :unresolved

    assert {:error, %Error{code: "STALE_RECORD"}} =
             RenewalCollectionAttempts.claim_dispatch_for_system(%DispatchInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 1
             })

    assert {:ok, same_resume} =
             RenewalCollectionAttempts.resume_after_fence_for_system(%ResumeInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 1,
               reservation_generation_id: resumed.reservation_generation_id
             })

    assert same_resume.id == resumed.id

    assert Repo.get_by!(InventoryReservation, reservation_key: reservation_key).state ==
             :cancelled

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE renewal_collection_attempts SET dispatch_epoch = 4 WHERE id = $1",
        [Ecto.UUID.dump!(collection.id)]
      )
    end
  end

  test "fence fails closed when the collection-owned generation is no longer active" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    collection = start_collection!(attempt)
    generation_id = Ash.UUIDv7.generate()
    key = reservation_key(attempt, collection, generation_id)

    assert {:ok, _} =
             Store.Orders.reserve_exact_generation(
               attempt.order_id,
               attempt.variant_id,
               key,
               attempt.quantity
             )

    assert {:ok, assigned} =
             RenewalCollectionAttempts.assign_reservation_generation_for_system(
               %ReservationGenerationInput{
                 collection_attempt_id: collection.id,
                 expected_dispatch_epoch: 1,
                 reservation_generation_id: generation_id
               }
             )

    assert {:ok, %{reservation: %{state: :cancelled}, changed?: true}} =
             Store.Orders.release_exact_generation(attempt.order_id, attempt.variant_id, key)

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             RenewalCollectionAttempts.fence_before_submission_for_system(%FenceInput{
               collection_attempt_id: collection.id,
               expected_dispatch_epoch: 1,
               fence_event_id: Ash.UUIDv7.generate()
             })

    reloaded = fetch_collection!(assigned.id)
    assert reloaded.dispatch_state == :not_started
    assert reloaded.dispatch_epoch == 1
    assert reloaded.fenced_through_epoch == 0
    assert reloaded.reservation_generation_id == generation_id
    assert reloaded.financial_outcome == :unresolved
  end

  test "PaymentIntent identity is exact and one PaymentIntent cannot attach twice" do
    fixture = subscription_fixture!()
    attempt = renewal_attempt!(fixture)
    first = start_collection!(attempt)
    intent = create_payment_intent!(attempt, first)

    assert {:ok, attached} = attach_payment_intent(first, intent)
    assert attached.payment_intent_id == intent.id
    assert {:ok, replay} = attach_payment_intent(first, intent)
    assert replay.payment_intent_id == intent.id

    other_fixture = subscription_fixture!()
    other_attempt = renewal_attempt!(other_fixture)
    other_collection = start_collection!(other_attempt)

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             attach_payment_intent(other_collection, intent)

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE renewal_collection_attempts SET payment_intent_id = $1 WHERE id = $2",
        [Ecto.UUID.dump!(intent.id), Ecto.UUID.dump!(other_collection.id)]
      )
    end
  end

  test "an unbound RenewalAttempt cannot start a collection" do
    fixture = subscription_fixture!()

    unbound =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: fixture.subscription.id,
          period_start_at: fixture.subscription.current_period_end_at,
          period_end_at:
            DateTime.add(fixture.subscription.current_period_end_at, 86_400, :second),
          renewal_key: "unbound:#{fixture.subscription.id}"
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:error, %Error{code: "INVALID_STATE_TRANSITION"}} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: unbound.id
             })

    assert collection_count(unbound.id) == 0
  end

  defp subscription_fixture! do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_04_collection")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        create_payment_intent?: false
      })

    Map.merge(fixture, %{
      customer: customer,
      product: product,
      variant: variant,
      plan: plan,
      variant_plan: variant_plan
    })
  end

  defp renewal_attempt!(fixture) do
    subscription = fixture.subscription
    revision = fixture.revision
    period = Scheduler.next_period(subscription.current_period_end_at, revision)

    snapshot = %{
      "version" => 1,
      "subscription_plan_key" => fixture.plan.key,
      "interval_unit" => Atom.to_string(revision.interval_unit),
      "interval_count" => revision.interval_count,
      "trial_days" => revision.trial_days,
      "anchor_mode" => Atom.to_string(revision.anchor_mode),
      "anchor_day_of_month" => revision.anchor_day_of_month,
      "billing_timezone" => revision.billing_timezone,
      "term_mode" => Atom.to_string(revision.term_mode),
      "term_cycles" => revision.term_cycles,
      "term_end_at" => datetime_snapshot(revision.term_end_at),
      "access_on_past_due" => Atom.to_string(revision.access_on_past_due),
      "access_on_cancel" => Atom.to_string(revision.access_on_cancel),
      "grace_period_days" => revision.grace_period_days,
      "max_retry_attempts" => revision.max_retry_attempts,
      "retry_schedule_hours" => revision.retry_schedule_hours,
      "entitlement_kind" => enum_snapshot(revision.entitlement_kind),
      "entitlement_scope_key" => revision.entitlement_scope_key
    }

    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: subscription.id,
        period_start_at: subscription.current_period_end_at,
        period_end_at: period.current_period_end_at,
        renewal_key: Scheduler.renewal_key(subscription.id, period.current_period_end_at),
        order_id: fixture.order.id,
        plan_revision_id: revision.id,
        variant_id: subscription.variant_id,
        quantity: subscription.quantity,
        amount_minor: revision.amount_minor,
        currency: revision.currency,
        expected_subscription_version: subscription.aggregate_version,
        charged_contract_version: 1,
        charged_contract_snapshot: snapshot,
        status: :pending
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp start_collection!(attempt) do
    assert {:ok, collection} =
             RenewalCollectionAttempts.start_for_system(%StartInput{
               renewal_attempt_id: attempt.id
             })

    collection
  end

  defp create_payment_intent!(attempt, collection) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        order_id: attempt.order_id,
        amount_received_minor: attempt.amount_minor,
        currency: attempt.currency,
        provider: :stripe,
        payment_intent_key: RenewalCollectionAttempts.payment_intent_key(collection.id)
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp attach_payment_intent(collection, intent) do
    RenewalCollectionAttempts.attach_payment_intent_for_system(%AttachPaymentIntentInput{
      collection_attempt_id: collection.id,
      payment_intent_id: intent.id
    })
  end

  defp claim(collection) do
    RenewalCollectionAttempts.claim_dispatch_for_system(%DispatchInput{
      collection_attempt_id: collection.id,
      expected_dispatch_epoch: collection.dispatch_epoch
    })
  end

  defp payment_intent_transition!(intent, action) do
    intent
    |> Ash.Changeset.for_update(action, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp set_past_due!(subscription, next_retry_at, attempt_count \\ 1) do
    subscription
    |> Ash.Changeset.for_update(
      :mark_past_due_transition,
      %{
        billing_status_reason: "PAYMENT_FAILED",
        past_due_since_at: DateTime.add(next_retry_at, -86_400, :second),
        dunning_attempt_count: attempt_count,
        next_retry_at: next_retry_at,
        retry_suppressed_at: nil
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp collection_count(renewal_attempt_id) do
    Repo.aggregate(
      from(collection in RenewalCollectionAttempt,
        where: collection.renewal_attempt_id == ^renewal_attempt_id
      ),
      :count,
      :id
    )
  end

  defp fetch_collection!(id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reservation_key(attempt, collection, generation_id) do
    "order:#{attempt.order_id}:sku:#{attempt.variant_id}:renewal_collection:#{collection.id}:generation:#{generation_id}"
  end

  defp create_committed_fixture! do
    fixture = Sandbox.unboxed_run(Store.Repo, fn -> subscription_fixture!() end)
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)
    fixture
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
      order_id = Ecto.UUID.dump!(fixture.order.id)
      variant_id = Ecto.UUID.dump!(fixture.variant.id)
      product_id = Ecto.UUID.dump!(fixture.product.id)
      plan_id = Ecto.UUID.dump!(fixture.plan.id)

      Repo.query!(
        "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
        [subscription_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp datetime_snapshot(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_snapshot(_value), do: nil
  defp enum_snapshot(nil), do: nil
  defp enum_snapshot(value) when is_atom(value), do: Atom.to_string(value)
end
