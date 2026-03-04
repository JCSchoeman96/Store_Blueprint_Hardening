defmodule Store.Payments.Providers.StripeSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Stripe
  alias Store.Payments.Types.CanonicalReceipt

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
end
