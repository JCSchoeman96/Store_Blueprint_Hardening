defmodule Store.Subscriptions.CancellationRenewalAuthorityTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Oban.Job
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.PaymentApplication
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
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

  test "a collection accepted before cancellation is remedied without reactivating the subscription" do
    customer = SubscriptionsFixtures.create_customer!("jc281_late_collection")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

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
    owner = self()
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)
      send(owner, {:stripe_charge_waiting, params})

      receive do
        :release_stripe_charge ->
          StripeAPIStub.json_response(
            conn,
            StripeAPIStub.payment_intent_response(params, %{"status" => "succeeded"})
          )
      after
        10_000 ->
          raise "timed out waiting to release the Stripe test charge"
      end
    end)

    task =
      Task.async(fn ->
        SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id, now: now)
      end)

    assert_receive {:stripe_charge_waiting, _params}, 5_000
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
    send(task.pid, :release_stripe_charge)
    assert {:ok, :processed} = Task.await(task, 10_000)

    order_id = attempt.order_id
    payment_intent_id = attempt.payment_intent_id
    order = fetch_order!(order_id)
    payment_intent = fetch_payment_intent!(payment_intent_id)

    assert order.state == :paid
    assert payment_intent.state == :succeeded
    assert count_payment_applications(order_id) == 1

    assert :ok ==
             ReconcilePaidSubscriptionRenewalWorker.perform(%Job{
               args: %{"order_id" => order_id, "renewal_attempt_id" => attempt.id}
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
end
