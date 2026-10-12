defmodule Store.Subscriptions.CancellationRenewalAuthorityTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Oban.Job
  alias Store.Digital.{DigitalAsset, DownloadGrant, ProductDigitalLink}
  alias Store.Digital.Workers.IssueGrantsForPaidOrderWorker
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.PaymentApplication
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ReconcilePaidSubscriptionRenewalWorker

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "period-end cancellation preserves an active paid period" do
    customer = SubscriptionsFixtures.create_customer!("jc281_active_period_cancel")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc281-active"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_active_period",
        started_at: DateTime.add(now, -5 * 86_400, :second)
      })

    assert DateTime.compare(subscription.current_period_end_at, now) == :gt

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    after_boundary = DateTime.add(subscription.current_period_end_at, 1, :second)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: after_boundary
             )

    assert :atomics.get(post_count, 1) == 1
    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :processing
    assert count_payment_applications(attempt.order_id) == 0

    assert {:ok, canceled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert canceled.status == :active
    assert canceled.cancel_at_period_end
    assert canceled.current_period_end_at == subscription.current_period_end_at
    assert [%EntitlementGrant{status: :active}] = grants_for(subscription.id)
    assert fetch_attempt!(subscription.id).failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert count_refunds() == 0
    assert :atomics.get(post_count, 1) == 1

    assert {:ok, :noop} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: after_boundary
             )

    assert :atomics.get(post_count, 1) == 1
  end

  test "period-end cancellation preserves a terminal payment failure classification" do
    customer = SubscriptionsFixtures.create_customer!("jc281_terminal_failure_cancel")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_terminal_failure_cancel",
        started_at: DateTime.add(now, -5 * 86_400, :second)
      })

    enable_stripe!()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    after_boundary = DateTime.add(subscription.current_period_end_at, 1, :second)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: after_boundary
             )

    assert fetch_attempt!(subscription.id).failure_code == "PAYMENT_FAILED"

    assert {:ok, canceled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert canceled.status == :past_due
    assert canceled.cancel_at_period_end
    assert fetch_attempt!(subscription.id).failure_code == "PAYMENT_FAILED"
    assert count_refunds() == 0
  end

  test "cancellation fails closed when the Order is applied to another PaymentIntent" do
    customer = SubscriptionsFixtures.create_customer!("jc281_conflicting_application")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_conflicting_application",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)

    other_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: attempt.order_id,
        amount_received_minor: 1_999,
        currency: "USD",
        provider: :stripe
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    PaymentApplication
    |> Ash.Changeset.for_create(:apply_once, %{
      order_id: attempt.order_id,
      payment_intent_id: other_intent.id,
      application_key: "jc281-conflicting-application:#{attempt.id}"
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false, context: %{system?: true})

    assert {:error, %{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert fetch_subscription!(subscription.id).status == :active
    assert fetch_attempt!(subscription.id).failure_code == nil
    assert count_payment_applications(attempt.order_id) == 1
    assert count_refunds() == 0
  end

  test "period-end cancellation after the paid boundary terminalizes an unresolved renewal" do
    customer = SubscriptionsFixtures.create_customer!("jc281_expired_period_cancel")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc281-expired"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_expired_period",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    assert DateTime.compare(subscription.current_period_end_at, now) == :lt

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    enable_stripe!()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :processing
    assert attempt.order_id
    assert attempt.payment_intent_id
    assert count_payment_applications(attempt.order_id) == 0

    assert {:ok, canceled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert canceled.status == :canceled
    refute canceled.cancel_at_period_end
    assert canceled.next_renewal_at == nil
    assert canceled.next_retry_at == nil

    withdrawn = fetch_attempt!(subscription.id)
    assert withdrawn.status == :failed
    assert withdrawn.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert count_refunds() == 0
    assert [] == grants_for(subscription.id, :active)
  end

  test "an already-enqueued renewal worker does not charge after scheduled cancellation" do
    customer = SubscriptionsFixtures.create_customer!("jc281_enqueued_worker_cancel")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_enqueued_worker",
        started_at: DateTime.add(now, -5 * 86_400, :second)
      })

    assert {:ok, scheduled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert scheduled.status == :active
    assert scheduled.cancel_at_period_end

    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    after_boundary = DateTime.add(subscription.current_period_end_at, 1, :second)

    assert {:ok, :noop} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(
               subscription.id,
               now: after_boundary
             )

    assert :atomics.get(post_count, 1) == 0
    assert fetch_attempt!(subscription.id) == nil
  end

  test "payment application before period-end cancellation preserves the paid renewal" do
    customer = SubscriptionsFixtures.create_customer!("jc281_payment_first_period_end")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc281-payment-first"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_payment_first_period_end",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    enable_stripe!()

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :processing
    assert count_payment_applications(attempt.order_id) == 1

    assert {:ok, scheduled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert count_payment_applications(attempt.order_id) == 1

    assert scheduled.status == :active
    assert scheduled.cancel_at_period_end
    assert fetch_attempt!(subscription.id).failure_code == nil
    assert count_refunds() == 0

    assert {:ok, :reconciled} =
             SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id
             )

    reconciled = fetch_subscription!(subscription.id)
    assert reconciled.status == :active
    assert reconciled.cancel_at_period_end
    assert reconciled.current_period_start_at == attempt.period_start_at
    assert reconciled.current_period_end_at == attempt.period_end_at

    assert [%EntitlementGrant{status: :active, valid_to_at: valid_to_at}] =
             grants_for(subscription.id, :active)

    assert valid_to_at == attempt.period_end_at
    assert count_refunds() == 0
  end

  test "payment application before cancel-now preserves payment history without reactivation" do
    customer = SubscriptionsFixtures.create_customer!("jc281_payment_first_now")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc281-payment-first-now"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_payment_first_now",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    enable_stripe!()

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)
    assert count_payment_applications(attempt.order_id) == 1

    assert {:ok, canceled} =
             SubscriptionsFacade.cancel_subscription_for_user(customer, subscription.id, :now)

    assert canceled.status == :canceled
    assert [] == grants_for(subscription.id, :active)
    assert [%EntitlementGrant{status: :revoked}] = grants_for(subscription.id, :revoked)
    assert count_refunds() == 0

    assert {:ok, :noop} =
             SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id
             )

    assert fetch_subscription!(subscription.id).status == :canceled
    assert fetch_attempt!(subscription.id).status == :succeeded
    assert count_payment_applications(attempt.order_id) == 1
  end

  test "payment application and cancellation serialize on the renewal Order" do
    payment_first = create_committed_renewal_race_fixture!("payment_first")
    payment_first_attempt = process_committed_renewal!(payment_first)

    {payment_result, payment_first_cancel_result} =
      race_cancellation_and_payment!(payment_first, payment_first_attempt, :payment_first)

    assert {:ok, %{applied?: true}} = payment_result
    assert {:ok, %{status: :active, cancel_at_period_end: true}} = payment_first_cancel_result
    assert count_payment_applications(payment_first_attempt.order_id) == 1

    assert {:ok, :reconciled} =
             unboxed_reconcile_renewal(payment_first_attempt)

    payment_first_subscription = fetch_subscription!(payment_first.subscription_id)
    assert payment_first_subscription.status == :active
    assert payment_first_subscription.cancel_at_period_end
    assert payment_first_subscription.current_period_end_at == payment_first_attempt.period_end_at
    assert fetch_attempt!(payment_first.subscription_id).status == :succeeded

    assert refunds_for(payment_first_attempt.order_id, payment_first_attempt.payment_intent_id) ==
             []

    cancellation_first = create_committed_renewal_race_fixture!("cancellation_first")
    cancellation_first_attempt = process_committed_renewal!(cancellation_first)

    {cancellation_first_payment_result, cancellation_first_cancel_result} =
      race_cancellation_and_payment!(
        cancellation_first,
        cancellation_first_attempt,
        :cancellation_first
      )

    assert {:ok, %{status: :canceled, cancel_at_period_end: false}} =
             cancellation_first_cancel_result

    assert {:ok, %{applied?: true}} = cancellation_first_payment_result
    assert count_payment_applications(cancellation_first_attempt.order_id) == 1
    assert fetch_order!(cancellation_first_attempt.order_id).state == :paid
    assert fetch_payment_intent!(cancellation_first_attempt.payment_intent_id).state == :succeeded

    assert fetch_attempt!(cancellation_first.subscription_id).failure_code ==
             "RENEWAL_AUTHORITY_WITHDRAWN"

    assert {:ok, :noop} = unboxed_reconcile_renewal(cancellation_first_attempt)

    cancellation_first_subscription = fetch_subscription!(cancellation_first.subscription_id)
    assert cancellation_first_subscription.status == :canceled

    assert cancellation_first_subscription.current_period_end_at ==
             cancellation_first.subscription.current_period_end_at

    assert length(
             refunds_for(
               cancellation_first_attempt.order_id,
               cancellation_first_attempt.payment_intent_id
             )
           ) == 1
  end

  test "cancellation after binding but before provider dispatch blocks the charge" do
    customer = SubscriptionsFixtures.create_customer!("jc281_cancel_before_dispatch")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_before_dispatch",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()
    owner = self()
    handler_id = "jc281-cancel-before-dispatch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_check],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id do
            result =
              SubscriptionsFacade.cancel_subscription_for_user(
                config.customer,
                config.subscription_id,
                :period_end
              )

            send(config.owner, {:canceled_before_dispatch, result})
          end
        end,
        %{customer: customer, owner: owner, subscription_id: subscription.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:canceled_before_dispatch, {:ok, %{status: :canceled}}}
    assert :atomics.get(post_count, 1) == 0
    assert fetch_subscription!(subscription.id).status == :canceled

    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
  end

  test "cancellation after checkout binding but before processing mark is not overwritten" do
    customer = SubscriptionsFixtures.create_customer!("jc281_cancel_during_binding")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_during_binding",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()
    owner = self()
    handler_id = "jc281-cancel-during-binding-#{System.unique_integer([:positive])}"
    post_count = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :renewal_attempt_before_processing],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id do
            result =
              SubscriptionsFacade.cancel_subscription_for_user(
                config.customer,
                config.subscription_id,
                :period_end
              )

            send(config.owner, {:canceled_during_binding, result})
          end
        end,
        %{customer: customer, owner: owner, subscription_id: subscription.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:canceled_during_binding, {:ok, %{status: :canceled}}}
    assert :atomics.get(post_count, 1) == 0
    assert fetch_subscription!(subscription.id).status == :canceled

    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :failed
    assert attempt.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert attempt.order_id
    assert is_nil(attempt.payment_intent_id)
  end

  test "payment fanout fails closed when an Order has duplicate renewal bindings" do
    customer = SubscriptionsFixtures.create_customer!("jc281_duplicate_renewal_binding")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_duplicate_renewal_binding",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)
    duplicate = create_duplicate_renewal_attempt!(attempt)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)
    observation = authoritative_success_observation(payment_intent)

    assert duplicate.order_id == attempt.order_id
    assert duplicate.payment_intent_id == attempt.payment_intent_id

    assert {:error, %Error{code: "PAYMENT_EVENT_UNVERIFIED"}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert fetch_order!(attempt.order_id).state == :paid
    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert count_payment_applications(attempt.order_id) == 1

    assert [] ==
             all_enqueued(
               worker: ReconcilePaidSubscriptionRenewalWorker,
               args: %{"order_id" => attempt.order_id, "renewal_attempt_id" => attempt.id}
             )
  end

  test "a late success after cancellation is remediated without granting digital access" do
    customer = SubscriptionsFixtures.create_customer!("jc281_late_collection")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    digital_asset = create_digital_asset!()
    create_variant_digital_link!(variant.id, digital_asset.id)

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc281-late-collection"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc281_late_collection",
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    enable_stripe!()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    assert {:ok, :processed} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    attempt = fetch_attempt!(subscription.id)
    assert attempt.status == :processing
    assert count_payment_applications(attempt.order_id) == 0

    assert {:ok, canceled} =
             SubscriptionsFacade.cancel_subscription_for_user(
               customer,
               subscription.id,
               :period_end
             )

    assert canceled.status == :canceled
    assert fetch_attempt!(subscription.id).failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"

    order_id = attempt.order_id
    payment_intent_id = attempt.payment_intent_id
    payment_intent = fetch_payment_intent!(payment_intent_id)

    observation = authoritative_success_observation(payment_intent)

    handler_id = "jc281-payment-application-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :payments, :interlock_apply_payment_success_once],
        fn _event, _measurements, metadata, owner -> send(owner, {:apply_once, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    apply_result =
      Store.Payments.record_and_apply_payment_observation_for_system(payment_intent, observation)

    assert {:ok, %{outcome: :authoritative_success}} = apply_result
    assert_receive {:apply_once, %{replay: false, outcome: :ok}}

    assert fetch_order!(order_id).state == :paid
    assert fetch_payment_intent!(payment_intent_id).state == :succeeded
    assert count_payment_applications(order_id) == 1

    assert [] ==
             all_enqueued(
               worker: IssueGrantsForPaidOrderWorker,
               args: %{"order_id" => order_id}
             )

    assert [] ==
             DownloadGrant
             |> Ash.Query.filter(expr(order_id == ^order_id))
             |> Ash.read!(domain: Store.Digital, authorize?: false, context: %{system?: true})

    reconciliation_args = %{"order_id" => order_id, "renewal_attempt_id" => attempt.id}

    assert [reconciliation_job] =
             all_enqueued(
               worker: ReconcilePaidSubscriptionRenewalWorker,
               args: reconciliation_args
             )

    Store.DirectRepo.delete!(reconciliation_job)

    assert [] ==
             all_enqueued(
               worker: ReconcilePaidSubscriptionRenewalWorker,
               args: reconciliation_args
             )

    assert {:ok, %{outcome: :already_applied_success}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               observation
             )

    assert [_replayed_reconciliation_job] =
             all_enqueued(
               worker: ReconcilePaidSubscriptionRenewalWorker,
               args: reconciliation_args
             )

    assert {:ok, %{applied?: false}} =
             Store.Payments.apply_payment_success_once(payment_intent_id)

    assert [_idempotent_reconciliation_job] =
             all_enqueued(
               worker: ReconcilePaidSubscriptionRenewalWorker,
               args: reconciliation_args
             )

    assert :ok ==
             ReconcilePaidSubscriptionRenewalWorker.perform(%Job{
               args: reconciliation_args
             })

    assert :ok ==
             ReconcilePaidSubscriptionRenewalWorker.perform(%Job{
               args: %{"order_id" => order_id, "renewal_attempt_id" => attempt.id}
             })

    assert fetch_subscription!(subscription.id).status == :canceled

    assert fetch_subscription!(subscription.id).current_period_end_at ==
             subscription.current_period_end_at

    withdrawn = fetch_attempt!(subscription.id)
    assert withdrawn.status == :failed
    assert withdrawn.failure_code == "RENEWAL_AUTHORITY_WITHDRAWN"
    assert [] == grants_for(subscription.id, :active)

    refunds = refunds_for(order_id, payment_intent_id)
    assert length(refunds) == 1
    assert hd(refunds).requested_amount_minor == payment_intent.amount_received_minor
    assert hd(refunds).currency == payment_intent.currency
    assert hd(refunds).reason == "renewal_collected_after_cancellation"
    assert hd(refunds).scope_kind == :full_refund

    assert hd(refunds).idempotency_key ==
             "renewal-cancel-remediation:#{attempt.id}:#{payment_intent.id}"

    refund_receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: :stripe,
          raw_body:
            Jason.encode!(%{
              "event_type" => "refund.succeeded",
              "provider_event_id" => "evt_jc281_refund_#{attempt.id}",
              "refund" => %{
                "id" => "re_jc281_refund_#{attempt.id}",
                "idempotency_key" => hd(refunds).idempotency_key
              }
            }),
          headers: %{"content-type" => ["application/json"]}
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    assert :ok = Store.Payments.process_refund_webhook_receipt(refund_receipt)
    assert fetch_order!(order_id).state == :refunded

    assert {:ok, %{applied?: false}} =
             Store.Payments.apply_payment_success_once(payment_intent_id)

    assert count_payment_applications(order_id) == 1

    assert :ok ==
             ReconcilePaidSubscriptionRenewalWorker.perform(%Job{
               args: %{"order_id" => order_id, "renewal_attempt_id" => attempt.id}
             })

    assert length(refunds_for(order_id, payment_intent_id)) == 1

    assert :atomics.get(post_count, 1) == 1
  end

  defp enable_stripe! do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )
  end

  defp create_committed_renewal_race_fixture!(suffix) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        unique = "#{suffix}_#{Ecto.UUID.generate()}"
        customer = SubscriptionsFixtures.create_customer!("jc281_race_#{unique}")

        %{product: product, variant: variant} =
          SubscriptionsFixtures.create_subscription_sellable!()

        plan = SubscriptionsFixtures.create_subscription_plan!()
        attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            provider_billing_ref: "pm_jc281_race_#{unique}",
            started_at: DateTime.add(now, -40 * 86_400, :second)
          })

        %{
          attachment_id: attachment.id,
          customer: customer,
          customer_id: customer.id,
          line_item_id: line_item.id,
          order_id: order.id,
          plan_id: plan.id,
          product_id: product.id,
          revision_id: revision.id,
          subscription: subscription,
          subscription_id: subscription.id,
          variant_id: variant.id
        }
      end)

    on_exit(fn -> cleanup_committed_renewal_race_fixture!(fixture) end)
    fixture
  end

  defp process_committed_renewal!(fixture) do
    enable_stripe!()

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, :processed} =
             Sandbox.unboxed_run(Repo, fn ->
               SubscriptionsFacade.process_due_subscription_renewal_for_system(
                 fixture.subscription_id,
                 now: now
               )
             end)

    attempt = fetch_attempt!(fixture.subscription_id)
    assert attempt.status == :processing
    assert attempt.order_id
    assert attempt.payment_intent_id
    assert count_payment_applications(attempt.order_id) == 0
    attempt
  end

  defp unboxed_reconcile_renewal(attempt) do
    Sandbox.unboxed_run(Repo, fn ->
      Sandbox.unboxed_run(Store.DirectRepo, fn ->
        SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
          renewal_attempt_id: attempt.id
        )
      end)
    end)
  end

  defp race_cancellation_and_payment!(fixture, attempt, first_operation) do
    parent = self()
    lock_holder = start_order_lock_holder(attempt.order_id, parent)
    assert_receive {:renewal_order_locked, blocker_pid}

    operations = %{
      cancellation: fn ->
        SubscriptionsFacade.cancel_subscription_for_user(
          fixture.customer,
          fixture.subscription_id,
          :period_end
        )
      end,
      payment: fn -> Store.Payments.apply_payment_success_once(attempt.payment_intent_id) end
    }

    first = if first_operation == :payment_first, do: :payment, else: :cancellation
    second = if first == :payment, do: :cancellation, else: :payment

    try do
      first_task = start_unboxed_race_operation(first, operations[first], parent)
      assert_receive {:renewal_race_operation_started, ^first}
      await_order_waiters!(blocker_pid, 1)

      second_task = start_unboxed_race_operation(second, operations[second], parent)
      assert_receive {:renewal_race_operation_started, ^second}
      await_order_waiters!(blocker_pid, 2)

      send(lock_holder.pid, :release)
      assert {:ok, :released} = Task.await(lock_holder, 10_000)

      first_result = Task.await(first_task, 10_000)
      second_result = Task.await(second_task, 10_000)

      results = %{first => first_result, second => second_result}
      {results[:payment], results[:cancellation]}
    after
      if Process.alive?(lock_holder.pid) do
        send(lock_holder.pid, :release)
      end
    end
  end

  defp start_order_lock_holder(order_id, parent) do
    Task.async(fn -> run_order_lock_holder(order_id, parent) end)
  end

  defp run_order_lock_holder(order_id, parent) do
    Sandbox.unboxed_run(Repo, fn -> hold_order_lock(order_id, parent) end)
  end

  defp hold_order_lock(order_id, parent) do
    Repo.transaction(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()")

      Repo.query!(
        "SELECT id FROM orders WHERE id = $1::text::uuid FOR UPDATE",
        [order_id]
      )

      send(parent, {:renewal_order_locked, backend_pid})

      receive do
        :release -> :released
      after
        10_000 -> Repo.rollback(:renewal_order_lock_holder_timeout)
      end
    end)
  end

  defp start_unboxed_race_operation(name, operation, parent) do
    Task.async(fn -> run_unboxed_race_operation(name, operation, parent) end)
  end

  defp run_unboxed_race_operation(name, operation, parent) do
    Sandbox.unboxed_run(Repo, fn ->
      run_direct_race_operation(name, operation, parent)
    end)
  end

  defp run_direct_race_operation(name, operation, parent) do
    Sandbox.unboxed_run(Store.DirectRepo, fn ->
      send(parent, {:renewal_race_operation_started, name})
      operation.()
    end)
  end

  defp await_order_waiters!(blocker_pid, expected, attempts_left \\ 500)

  defp await_order_waiters!(blocker_pid, expected, attempts_left) when attempts_left > 0 do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT count(*)
        FROM pg_stat_activity waiting
        WHERE waiting.wait_event_type = 'Lock'
          AND (
            $1 = ANY(pg_blocking_pids(waiting.pid))
            OR EXISTS (
              SELECT 1
              FROM pg_stat_activity queued
              WHERE $1 = ANY(pg_blocking_pids(queued.pid))
                AND queued.pid = ANY(pg_blocking_pids(waiting.pid))
            )
          )
        """,
        [blocker_pid]
      )

    if count >= expected do
      :ok
    else
      Process.sleep(10)
      await_order_waiters!(blocker_pid, expected, attempts_left - 1)
    end
  end

  defp await_order_waiters!(_blocker_pid, expected, _attempts_left) do
    flunk("expected #{expected} payment/cancellation writers to wait for the renewal Order")
  end

  defp cleanup_committed_renewal_race_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      sub_id = Ecto.UUID.dump!(fixture.subscription_id)
      user_id = Ecto.UUID.dump!(fixture.customer_id)
      product_id = Ecto.UUID.dump!(fixture.product_id)
      plan_id = Ecto.UUID.dump!(fixture.plan_id)
      revision_id = Ecto.UUID.dump!(fixture.revision_id)

      Repo.query!(
        """
        DELETE FROM oban_jobs
        WHERE args->>'subscription_id' = $1
          OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)
          OR args->>'email_outbox_id' IN (
            SELECT id::text
            FROM email_outboxes
            WHERE subscription_id = $1::text::uuid
              OR order_id IN (SELECT id FROM orders WHERE user_id = $2)
              OR refund_id IN (
                SELECT id FROM refunds WHERE order_id IN (
                  SELECT id FROM orders WHERE user_id = $2
                )
              )
          )
        """,
        [fixture.subscription_id, user_id]
      )

      Repo.query!(
        "DELETE FROM refund_attempts WHERE refund_id IN (SELECT id FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR refund_id IN (SELECT id FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $2))",
        [sub_id, user_id]
      )

      Repo.query!(
        "DELETE FROM order_adjustments WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [sub_id])

      Repo.query!(
        "DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1",
        [sub_id]
      )

      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [sub_id])

      Repo.query!(
        "DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [revision_id])

      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [
        Ecto.UUID.dump!(fixture.attachment_id)
      ])

      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_order!(order_id) do
    Store.Orders.Order
    |> Ash.Query.filter(expr(id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp fetch_payment_intent!(payment_intent_id) do
    Store.Payments.PaymentIntent
    |> Ash.Query.filter(expr(id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp refunds_for(order_id, payment_intent_id) do
    Store.Payments.Refund
    |> Ash.Query.filter(expr(order_id == ^order_id and payment_intent_id == ^payment_intent_id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp grants_for(subscription_id, status \\ nil) do
    query = EntitlementGrant |> Ash.Query.filter(expr(source_id == ^subscription_id))
    query = if status, do: Ash.Query.filter(query, expr(status == ^status)), else: query

    Ash.read!(query,
      domain: Store.Entitlements,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp count_payment_applications(order_id) do
    Repo.query!(
      "SELECT count(*) FROM payment_applications WHERE order_id = $1::text::uuid",
      [order_id]
    )
    |> Map.fetch!(:rows)
    |> List.first()
    |> List.first()
  end

  defp count_refunds do
    Repo.query!("SELECT count(*) FROM refunds")
    |> Map.fetch!(:rows)
    |> List.first()
    |> List.first()
  end

  defp create_digital_asset! do
    DigitalAsset
    |> Ash.Changeset.for_create(:create, %{
      key: "jc281-asset-#{System.unique_integer([:positive])}",
      title: "JC-281 renewal asset",
      content_type: "application/pdf",
      byte_size: 1024,
      storage_provider: "s3",
      storage_bucket: "downloads-bucket",
      storage_object_key: "assets/jc281.pdf",
      status: :active
    })
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_variant_digital_link!(variant_id, asset_id) do
    ProductDigitalLink
    |> Ash.Changeset.for_create(
      :create,
      %{variant_id: variant_id, digital_asset_id: asset_id, position: 0},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_duplicate_renewal_attempt!(%RenewalAttempt{} = attempt) do
    attrs =
      Map.take(attempt, [
        :subscription_id,
        :period_start_at,
        :period_end_at,
        :renewal_key,
        :plan_revision_id,
        :variant_id,
        :quantity,
        :amount_minor,
        :currency,
        :contract_change_id,
        :expected_subscription_version,
        :charged_contract_version,
        :charged_contract_snapshot,
        :status,
        :order_id,
        :payment_intent_id,
        :failure_code,
        :failure_message,
        :attempt_no
      ])
      |> Map.update!(:renewal_key, &(&1 <> ":duplicate"))

    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp authoritative_success_observation(%PaymentIntent{} = payment_intent) do
    %ProviderObservation{
      provider: :stripe,
      provider_reference: payment_intent.provider_payment_id,
      provider_reference_kind: :payment_intent,
      provider_transaction_id: payment_intent.provider_payment_id,
      local_payment_intent_id: payment_intent.id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: payment_intent.amount_received_minor,
      currency: payment_intent.currency,
      provider_environment: "test",
      observed_at: DateTime.utc_now()
    }
  end
end
