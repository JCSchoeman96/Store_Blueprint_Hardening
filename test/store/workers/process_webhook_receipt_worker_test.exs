defmodule Store.Workers.ProcessWebhookReceiptWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.InventoryItem
  alias Store.Comms.EmailOutbox
  alias Store.Orders.InventoryReservation
  alias Store.Orders.{Order, PaymentApplication}
  alias Store.Payments.{ObservationEvidence, PaymentAttempt, PaymentIntent, WebhookReceipt}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Pricing.TaxRate
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Subscriptions.{StoredPaymentMethod, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.{ProcessSubscriptionRenewalWorker, ProcessWebhookReceiptWorker}

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "worker performs apply-once payment success transition and order effects" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_payment_success_001",
        "created" => 1_700_000_000,
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "metadata" => %{}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_payment_success_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert {:ok, [payment_attempt]} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert payment_attempt.provider_event_id == "evt_worker_payment_success_001"
    assert payment_attempt.provider_reference == payment_intent.id
    assert payment_attempt.observation_source == "webhook"
    assert payment_attempt.outcome == "authoritative_success"
    assert DateTime.to_unix(payment_attempt.provider_occurred_at) == 1_700_000_000
    assert %DateTime{} = payment_attempt.observed_at
    refute payment_attempt.provider_occurred_at == payment_attempt.observed_at

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert 1 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  test "the same verify observation is idempotent and later success remains durable after failure" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_observation_replay"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    failure = provider_observation(:failure_observation, "requires_payment_method")
    success = provider_observation(:authoritative_success, "succeeded")

    assert {:ok, _} = ObservationEvidence.record(payment_intent, failure)
    assert {:ok, _} = ObservationEvidence.record(payment_intent, failure)
    assert {:ok, _} = ObservationEvidence.record(payment_intent, success)

    assert {:ok, attempts} =
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.Query.sort(observed_at: :asc)
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert Enum.map(attempts, & &1.outcome) |> Enum.sort() ==
             Enum.sort(["failure_observation", "authoritative_success"])

    assert Enum.map(attempts, & &1.provider_reference) == [
             "pi_observation_replay",
             "pi_observation_replay"
           ]

    reverse_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_observation_reverse"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    reverse_success = %{
      success
      | provider_reference: "pi_observation_reverse",
        provider_transaction_id: "pi_observation_reverse"
    }

    reverse_failure = %{
      failure
      | provider_reference: "pi_observation_reverse",
        provider_transaction_id: "pi_observation_reverse"
    }

    assert {:ok, _} = ObservationEvidence.record(reverse_intent, reverse_success)
    assert {:ok, _} = ObservationEvidence.record(reverse_intent, reverse_failure)

    assert 2 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^reverse_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp provider_observation(outcome, status) do
    %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_observation_replay",
      provider_transaction_id: "pi_observation_replay",
      observation_source: :verification,
      normalized_outcome: outcome,
      raw_provider_status: status,
      amount_minor: 2500,
      currency: "USD",
      observed_at: DateTime.utc_now(),
      evidence_sha256: :crypto.hash(:sha256, status) |> Base.encode16(case: :lower)
    }
  end

  test "provider reconciliation stores evidence without applying commerce effects" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_reconcile_read"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_payment_observation("pi_reconcile_read", %{
      "amount" => 2500,
      "amount_received" => 2500,
      "currency" => "usd",
      "id" => "pi_reconcile_read",
      "metadata" => %{"local_intent_id" => payment_intent.id},
      "status" => "succeeded"
    })

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, result} = Store.Payments.Facade.observe_payment_intent_for_system(input)
    assert result.eligibility == :eligible
    assert result.evidence.provider_event_id == nil
    assert result.evidence.provider_reference == "pi_reconcile_read"
    assert fetch_payment_intent!(payment_intent.id).state == :created
    assert result.observation.observation_source == :verification
  end

  test "a mismatched provider response remains durable and fails eligibility" do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_reconcile_mismatch"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    StripeAPIStub.stub_payment_observation("pi_reconcile_mismatch", %{
      "amount" => 2500,
      "amount_received" => 2499,
      "currency" => "usd",
      "id" => "pi_reconcile_mismatch",
      "status" => "succeeded"
    })

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: payment_intent.id
    }

    assert {:ok, result} = Store.Payments.Facade.observe_payment_intent_for_system(input)
    assert result.eligibility == {:error, :amount_mismatch}
    assert result.evidence.amount_minor == 2499
    assert result.evidence.outcome == "authoritative_success"
    assert fetch_payment_intent!(payment_intent.id).state == :created
  end

  test "concurrent duplicate observations produce one durable row", context do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        provider: :stripe,
        amount_received_minor: 2500,
        currency: "USD",
        provider_payment_id: "pi_concurrent_observation"
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    observation = %{
      provider_observation(:authoritative_success, "succeeded")
      | provider_reference: "pi_concurrent_observation",
        provider_transaction_id: "pi_concurrent_observation"
    }

    sandbox_owner = context.sandbox_owners[Store.Repo]

    assert 4 ==
             1..4
             |> Task.async_stream(
               fn _ ->
                 :ok = Sandbox.allow(Store.Repo, sandbox_owner, self())
                 ObservationEvidence.record(payment_intent, observation)
               end,
               max_concurrency: 4,
               timeout: 10_000
             )
             |> Enum.count(fn
               {:ok, {:ok, _attempt}} -> true
               _ -> false
             end)

    assert 1 ==
             PaymentAttempt
             |> Ash.Query.filter(expr(payment_intent_id == ^payment_intent.id))
             |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  test "worker falls back to metadata local_intent_id when provider payment id is not yet persisted" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_payment_success_metadata_001",
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => "pi_provider_late_001",
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "customer" => "cus_meta_001",
            "payment_method" => "pm_meta_001",
            "metadata" => %{"local_intent_id" => payment_intent.id}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_payment_success_metadata_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_payment_intent = fetch_payment_intent!(payment_intent.id)
    assert updated_payment_intent.state == :succeeded
    assert updated_payment_intent.provider_payment_id == "pi_provider_late_001"
    assert updated_payment_intent.provider_customer_ref == "cus_meta_001"
    assert updated_payment_intent.provider_payment_method_ref == "pm_meta_001"
    assert fetch_order!(order.id).state == :paid
  end

  test "worker records disabled-provider failure without applying transitions" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_provider_disabled_001",
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "metadata" => %{}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: :stripe,
          provider_event_id: "evt_worker_provider_disabled_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_receipt = fetch_receipt!(receipt.id)
    assert updated_receipt.processing_status == "failed"
    assert updated_receipt.error_code == "PAYMENT_PROVIDER_DISABLED"

    assert :submitted == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
  end

  test "worker processes setup_intent success, updates stored method, and retries past-due subscriptions immediately" do
    customer = SubscriptionsFixtures.create_customer!("phase27_setup_webhook")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_setup_retry_001",
        provider_billing_ref: nil,
        next_retry_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })

    past_due_subscription =
      subscription
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          past_due_since_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
          billing_status_reason: "PAYMENT_METHOD_REQUIRED"
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: :stripe,
          purpose: :subscription_payment_method_update,
          subscription_id: past_due_subscription.id,
          provider_customer_ref: "cus_setup_retry_001",
          amount_received_minor: 0,
          currency: "USD",
          payment_intent_key: "setup-webhook:#{past_due_subscription.id}"
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      |> then(fn created ->
        created
        |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
        |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
      end)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_setup_intent_success_001",
        "type" => "setup_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => "seti_provider_success_001",
            "currency" => "usd",
            "customer" => "cus_setup_retry_001",
            "payment_method" => "pm_setup_retry_001",
            "metadata" => %{
              "local_intent_id" => payment_intent.id,
              "subscription_id" => past_due_subscription.id,
              "currency" => "USD"
            }
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_setup_intent_success_001",
          event_type: "setup_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    updated_intent = fetch_payment_intent!(payment_intent.id)
    assert updated_intent.state == :succeeded
    assert updated_intent.provider_payment_id == "seti_provider_success_001"
    assert updated_intent.provider_payment_method_ref == "pm_setup_retry_001"

    updated_subscription = fetch_subscription!(past_due_subscription.id)
    assert updated_subscription.provider_billing_ref == "pm_setup_retry_001"
    assert updated_subscription.provider_customer_ref == "cus_setup_retry_001"
    assert is_binary(updated_subscription.stored_payment_method_id)
    assert updated_subscription.billing_status_reason == nil
    assert DateTime.compare(updated_subscription.next_retry_at, DateTime.utc_now()) in [:lt, :eq]

    assert_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => past_due_subscription.id}
    )

    assert 1 ==
             StoredPaymentMethod
             |> Ash.Query.filter(
               expr(
                 user_id == ^customer.id and provider_customer_ref == ^"cus_setup_retry_001" and
                   provider_payment_method_ref == ^"pm_setup_retry_001"
               )
             )
             |> Ash.count!(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  test "worker consumes physical renewal inventory exactly once on recurring payment success" do
    customer = SubscriptionsFixtures.create_customer!("phase27_webhook_consume")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 1
      })

    variant = set_variant_weight!(base_variant, 250)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase27_webhook_consume",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    configure_shipping_profile!(source_order, variant)

    assert {:ok, :processed} =
             Store.Subscriptions.Facade.process_due_subscription_renewal_for_system(
               subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :active

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_renewal_succeeded_001",
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "metadata" => %{"local_intent_id" => payment_intent.id}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_renewal_succeeded_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok = perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert fetch_payment_intent!(payment_intent.id).state == :succeeded
    assert fetch_order!(attempt.order_id).state == :paid

    consumed = fetch_reservation!(attempt.order_id, variant.id)
    assert consumed.id == reservation.id
    assert consumed.state == :consumed

    inventory_after_success = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory_after_success.reserved_count == 0
    assert inventory_after_success.stock_on_hand == 0

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^attempt.order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert :ok = perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    replayed = fetch_reservation!(attempt.order_id, variant.id)
    assert replayed.id == reservation.id
    assert replayed.state == :consumed

    inventory_after_replay = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory_after_replay.reserved_count == 0
    assert inventory_after_replay.stock_on_hand == 0

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^attempt.order_id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)
  end

  test "worker releases renewal inventory when a recurring payment webhook fails" do
    customer = SubscriptionsFixtures.create_customer!("phase27_webhook_release")

    %{variant: base_variant} =
      SubscriptionsFixtures.create_subscription_sellable!(%{
        base_variant_stock_on_hand: 1
      })

    variant = set_variant_weight!(base_variant, 250)

    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, order: source_order} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_billing_ref: "pm_phase27_webhook_release",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    configure_shipping_profile!(source_order, variant)

    assert {:ok, :processed} =
             Store.Subscriptions.Facade.process_due_subscription_renewal_for_system(
               subscription.id,
               now: now
             )

    attempt = fetch_latest_attempt!(subscription.id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_renewal_failed_001",
        "type" => "payment_intent.payment_failed",
        "data" => %{
          "object" => %{
            "id" => payment_intent.provider_payment_id,
            "amount_received" => payment_intent.amount_received_minor,
            "currency" => String.downcase(payment_intent.currency || "USD"),
            "metadata" => %{"local_intent_id" => payment_intent.id}
          }
        }
      })

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_renewal_failed_001",
          event_type: "payment_intent.payment_failed",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    reservation = fetch_reservation!(attempt.order_id, variant.id)
    assert reservation.state == :cancelled

    inventory = Repo.get_by!(InventoryItem, variant_id: variant.id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 1
  end

  defp create_submitted_payment_intent!(order_id) do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{order_id: order_id, provider: :stripe})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp create_order! do
    user =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_worker_receipt_user"))

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: 0,
        items_subtotal_minor: 0,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp fetch_receipt!(id) do
    assert {:ok, [receipt]} =
             WebhookReceipt
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    receipt
  end

  defp fetch_subscription!(id) do
    assert {:ok, [subscription]} =
             Subscription
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    subscription
  end

  defp fetch_latest_attempt!(subscription_id) do
    assert {:ok, [attempt | _]} =
             Store.Subscriptions.RenewalAttempt
             |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
             |> Ash.Query.sort(inserted_at: :desc, id: :desc)
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    attempt
  end

  defp fetch_reservation!(order_id, variant_id) do
    assert {:ok, [reservation | _]} =
             InventoryReservation
             |> Ash.Query.filter(expr(order_id == ^order_id and variant_id == ^variant_id))
             |> Ash.read(domain: Store.Orders, authorize?: false, context: %{system?: true})

    reservation
  end

  defp configure_shipping_profile!(%Order{} = order, variant) do
    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-ZONE-#{System.unique_integer([:positive])}",
          country_code: "US",
          region_code: "CA",
          active: true
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{code: "GROUND", name: "Ground", active: true, sort_order: 100},
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-TAX-#{System.unique_integer([:positive])}",
          country_code: "US",
          region_code: "CA",
          product_tax_category: "STANDARD",
          rate_basis_points: 0,
          shipping_taxable: true,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})

    _rule =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "WH-RULE-#{System.unique_integer([:positive])}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: "USD",
          shipping_cost_minor: 400,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: max(variant.weight_grams || 0, 0)
      })

    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)

    order
    |> Ash.Changeset.for_update(
      :set_shipping_address,
      %{
        shipping_country_code: "US",
        shipping_region_code: "CA",
        shipping_postal_code: "94105",
        shipping_address_line1: "1 Market St",
        shipping_address_line2: "Suite 100"
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> then(fn addressed ->
      addressed
      |> Ash.Changeset.for_update(
        :set_shipping_method,
        %{shipping_rate_code: option.shipping_method_code},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
    end)
    |> Ash.Changeset.for_update(
      :set_shipping_quote_evidence,
      %{
        shipping_quote_hash: option.quote_hash,
        shipping_quote_currency_code: option.currency_code,
        shipping_quote_amount_minor: option.amount_minor,
        shipping_weight_grams: option.shipping_weight_grams,
        shipping_method_code: option.shipping_method_code,
        shipping_rule_id: option.shipping_rule_id,
        shipping_zone_id: option.zone_id
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp set_variant_weight!(variant, weight_grams) do
    variant
    |> Ash.Changeset.for_update(
      :update,
      %{weight_grams: weight_grams},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end
end
