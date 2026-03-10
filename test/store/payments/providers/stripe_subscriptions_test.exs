defmodule Store.Payments.Providers.StripeSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Stripe
  alias Store.Payments.Types.CanonicalReceipt
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "stripe capabilities include provider-managed subscriptions" do
    capabilities = Stripe.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == true
    assert capabilities.supports_tokenization? == true
  end

  test "normalize_webhook handles subscription event payloads into canonical receipt" do
    payload = %{
      "id" => "evt_sub_001",
      "type" => "customer.subscription.created",
      "created" => 1_767_200_000,
      "data" => %{
        "object" => %{
          "id" => "sub_123",
          "amount" => 1_999,
          "currency" => "usd",
          "metadata" => %{"order_ref" => "ORD123"}
        }
      }
    }

    assert {:ok, %CanonicalReceipt{} = receipt} = Stripe.normalize_webhook(payload)
    assert receipt.provider == "stripe"
    assert receipt.provider_event_id == "evt_sub_001"
    assert receipt.event_type == "customer.subscription.created"
    assert receipt.amount_minor == 1_999
    assert receipt.currency == "USD"
    assert receipt.status == :unknown
  end

  test "create_intent response does not expose provider string field" do
    attrs = %{
      order_ref: "ORDP26STRIPE",
      order_id: "order_001",
      checkout_key: "checkout_key_001",
      local_intent_id: "pi_local_order_001",
      amount_minor: 1_999,
      currency: "USD",
      payment_intent_key: "pi_key_001",
      idempotency_key: "idem_001",
      return_url: "https://store.example/return",
      cancel_url: "https://store.example/cancel"
    }

    assert {:ok, payload} = Stripe.create_intent(attrs, [])
    refute Map.has_key?(payload, :provider)
    assert is_binary(payload.provider_session_id)
    assert is_binary(payload.provider_payment_id)
    assert is_binary(payload.provider_checkout_url)
  end

  test "create_intent switches to setup mode for zero-total subscription carts" do
    attrs = %{
      order_ref: "ORDP27SETUP",
      order_id: "order_setup_001",
      checkout_key: "checkout_setup_001",
      local_intent_id: "pi_local_setup_001",
      amount_minor: 0,
      currency: "USD",
      payment_intent_key: "pi_key_setup_001",
      idempotency_key: "idem_setup_001",
      return_url: "https://store.example/return",
      cancel_url: "https://store.example/cancel",
      has_subscription_lines?: true,
      save_payment_method_for_off_session?: true
    }

    assert {:ok, payload} = Stripe.create_intent(attrs, [])
    assert payload.checkout_mode == :setup
    assert payload.provider_payment_id == nil
    assert payload.provider_checkout_url =~ "checkout.stripe.test/session/"
  end

  test "charge_off_session returns provider payment details" do
    attrs = %{
      amount_minor: 1_999,
      currency: "USD",
      renewal_key: "renewal_sub_20260401",
      local_intent_id: "pi_local_001",
      order_id: "order_001",
      renewal_attempt_id: "attempt_001",
      subscription_id: "sub_001",
      provider_customer_ref: "cus_001",
      provider_payment_method_ref: "pm_001"
    }

    assert {:ok, payload} = Stripe.charge_off_session(attrs, [])
    assert payload.status == :succeeded
    assert payload.idempotency_key == "renewal_sub_20260401"
    assert payload.metadata.local_intent_id == "pi_local_001"
    assert payload.metadata.order_id == "order_001"
    assert payload.metadata.renewal_attempt_id == "attempt_001"
    assert payload.metadata.subscription_id == "sub_001"
    assert payload.provider_payment_id =~ "pi_test_"
    assert payload.provider_client_secret =~ payload.provider_payment_id
  end

  test "normalize_webhook extracts local payment intent metadata for off-session events" do
    payload = %{
      "id" => "evt_pi_001",
      "type" => "payment_intent.succeeded",
      "created" => 1_767_200_000,
      "data" => %{
        "object" => %{
          "id" => "pi_123",
          "amount_received" => 1_999,
          "currency" => "usd",
          "customer" => "cus_123",
          "payment_method" => "pm_123",
          "metadata" => %{
            "order_ref" => "ORD123",
            "local_intent_id" => "pi_local_123"
          }
        }
      }
    }

    assert {:ok, %CanonicalReceipt{} = receipt} = Stripe.normalize_webhook(payload)
    assert receipt.provider_session_id == nil
    assert receipt.provider_payment_id == "pi_123"
    assert receipt.provider_customer_ref == "cus_123"
    assert receipt.provider_payment_method_ref == "pm_123"
    assert receipt.local_payment_intent_id == "pi_local_123"
  end

  test "normalize_webhook handles setup_intent events for inline card updates" do
    payload = %{
      "id" => "evt_setup_001",
      "type" => "setup_intent.succeeded",
      "created" => 1_767_200_000,
      "data" => %{
        "object" => %{
          "id" => "seti_123",
          "currency" => "usd",
          "customer" => "cus_456",
          "payment_method" => "pm_456",
          "client_secret" => "seti_secret_456",
          "metadata" => %{
            "local_intent_id" => "pi_local_setup_123",
            "subscription_id" => "sub_123",
            "currency" => "USD"
          }
        }
      }
    }

    assert {:ok, %CanonicalReceipt{} = receipt} = Stripe.normalize_webhook(payload)
    assert receipt.status == :succeeded
    assert receipt.amount_minor == 0
    assert receipt.currency == "USD"
    assert receipt.provider_payment_id == "seti_123"
    assert receipt.provider_customer_ref == "cus_456"
    assert receipt.provider_payment_method_ref == "pm_456"
    assert receipt.local_payment_intent_id == "pi_local_setup_123"
    assert receipt.client_secret == "seti_secret_456"
  end
end
