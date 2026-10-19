defmodule Store.Subscriptions.Sbh3003RetryExhaustionTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{Facade, RenewalAttempt, Subscription}
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.SubscriptionsFixtures
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  test "zero retries leaves the failed occurrence past due and dormant without suspension effects" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_zero")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:sbh-30-03-zero"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    baseline_access_effect_count = access_effect_count(subscription.id)

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             Facade.run_due_renewals_for_system(now: now, limit: 20)

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{max_retry_attempts: 3, retry_schedule_hours: [0, 24, 72]},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    exhausted = fetch_subscription!(subscription.id)
    attempt = fetch_current_attempt!(subscription.id)

    assert exhausted.status == :past_due
    assert exhausted.past_due_since_at == now

    grace_period_days =
      fetch_current_attempt!(subscription.id).charged_contract_snapshot["grace_period_days"]

    assert exhausted.failed_payment_boundary_at ==
             DateTime.add(now, grace_period_days * 24 * 60 * 60, :second)

    assert exhausted.dunning_attempt_count == 1
    assert exhausted.billing_status_reason == "PAYMENT_METHOD_REQUIRED"
    assert exhausted.next_retry_at == nil
    assert %DateTime{} = exhausted.retry_suppressed_at
    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_METHOD_REQUIRED"
    assert is_nil(exhausted.ended_at)
    assert is_nil(exhausted.canceled_at)
    assert is_nil(exhausted.canceled_reason)

    assert [%EntitlementGrant{status: :active}] = source_grants!(subscription.id)
    assert access_effect_count(subscription.id) == baseline_access_effect_count
    assert {:ok, []} = read_due_subscriptions(now)

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             Facade.run_due_renewals_for_system(now: now, limit: 20)

    assert {:ok, :noop} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: DateTime.add(now, 1, :day),
               renewal_key: attempt.renewal_key
             )

    assert fetch_subscription!(subscription.id).status == :past_due
    assert fetch_subscription!(subscription.id).dunning_attempt_count == 1
    assert fetch_current_attempt!(subscription.id).id == attempt.id
    assert [%EntitlementGrant{status: :active}] = source_grants!(subscription.id)
  end

  test "the configured retry count is consumed once and exhaustion keeps the first failure anchor" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_retries")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 3,
        retry_schedule_hours: [0, 24, 72]
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
    first_failure = fetch_subscription!(subscription.id)
    boundary_at = first_failure.failed_payment_boundary_at
    assert %DateTime{} = boundary_at
    assert first_failure.dunning_attempt_count == 1
    assert first_failure.past_due_since_at == now
    assert first_failure.next_retry_at == now
    assert is_nil(first_failure.retry_suppressed_at)

    bound_attempt = fetch_current_attempt!(subscription.id)

    assert bound_attempt.charged_contract_snapshot["max_retry_attempts"] == 3

    grace_period_days = bound_attempt.charged_contract_snapshot["grace_period_days"]

    assert first_failure.failed_payment_boundary_at ==
             DateTime.add(now, grace_period_days * 24 * 60 * 60, :second)

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{grace_period_days: 0, max_retry_attempts: 0, retry_schedule_hours: [0]},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert fetch_current_attempt!(subscription.id).charged_contract_snapshot["grace_period_days"] ==
             grace_period_days

    final_failure =
      Enum.reduce(2..4, first_failure, fn expected_count, previous ->
        retry_at = previous.next_retry_at
        assert %DateTime{} = retry_at

        assert {:ok, %{due_count: 1, failed_count: 1}} =
                 Facade.run_due_renewals_for_system(now: retry_at, limit: 20)

        updated = fetch_subscription!(subscription.id)
        assert updated.status == :past_due
        assert updated.dunning_attempt_count == expected_count
        assert updated.past_due_since_at == now
        assert updated.failed_payment_boundary_at == boundary_at
        updated
      end)

    assert final_failure.status == :past_due
    assert final_failure.dunning_attempt_count == 4
    assert final_failure.next_retry_at == nil
    assert %DateTime{} = final_failure.retry_suppressed_at
    assert {:ok, []} = read_due_subscriptions(DateTime.add(now, 10, :day))

    assert {:ok, %{due_count: 0, success_count: 0, failed_count: 0}} =
             Facade.run_due_renewals_for_system(now: DateTime.add(now, 10, :day), limit: 20)
  end

  test "contract changes do not reopen an exhausted bound occurrence" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_contract_repair")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{max_retry_attempts: 0})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
    exhausted = fetch_subscription!(subscription.id)

    target_plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
    SubscriptionsFixtures.create_plan_revision!(target_plan)

    {:ok, input} =
      QueueSubscriptionPlanChangeInput.new(%{
        "subscription_id" => subscription.id,
        "subscription_plan_id" => target_plan.id
      })

    assert {:ok, changed} =
             Facade.queue_subscription_plan_change_for_user(customer, subscription.id, input)

    assert changed.status == :past_due
    assert changed.dunning_attempt_count == 1
    assert changed.retry_suppressed_at == exhausted.retry_suppressed_at
    assert changed.next_retry_at == nil

    refute_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => subscription.id}
    )
  end

  test "payment method replacement cannot reopen an exhausted bound occurrence" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("sbh_30_03_payment_repair")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{max_retry_attempts: 0})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 20)
    exhausted = fetch_subscription!(subscription.id)
    suppressed_at = exhausted.retry_suppressed_at
    provider_customer_ref = "cus_sbh_30_03_payment_repair"
    provider_payment_method_ref = "pm_sbh_30_03_payment_repair"

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          order_id: exhausted.source_order_id,
          amount_received_minor: plan.amount_minor,
          currency: plan.currency,
          provider: :stripe,
          provider_customer_ref: provider_customer_ref,
          provider_payment_method_ref: provider_payment_method_ref,
          payment_intent_key: "sbh-30-03:pm-update:#{subscription.id}",
          purpose: :subscription_payment_method_update,
          subscription_id: subscription.id
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert :ok = Facade.handle_payment_method_update_succeeded_for_system(payment_intent.id)

    repaired = fetch_subscription!(subscription.id)
    assert repaired.status == :past_due
    assert repaired.retry_suppressed_at == suppressed_at
    assert repaired.next_retry_at == nil
    assert repaired.dunning_attempt_count == 1
    assert repaired.provider_billing_ref == provider_payment_method_ref
    assert is_binary(repaired.stored_payment_method_id)

    refute_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => subscription.id}
    )
  end

  defp read_due_subscriptions(now) do
    Subscription
    |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: 20})
    |> Ash.read(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_current_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp source_grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp access_effect_count(subscription_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM access_effects WHERE subscription_id = $1", [
        Ecto.UUID.dump!(subscription_id)
      ])

    count
  end
end
