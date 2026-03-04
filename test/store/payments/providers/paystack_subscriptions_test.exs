defmodule Store.Payments.Providers.PaystackSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Paystack

  test "paystack recurring capability is disabled and unsupported contracts error explicitly" do
    capabilities = Paystack.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == false
    assert capabilities.supports_merchant_initiated_charges? == false

    assert {:error, verify_error} = Paystack.verify_webhook(%{}, "{}", [])
    assert verify_error.code == "PAYMENT_PROVIDER_VERIFICATION_FAILED"

    assert {:error, normalize_error} = Paystack.normalize_webhook(%{})
    assert normalize_error.code == "PAYMENT_PAYLOAD_INVALID"
  end
end
