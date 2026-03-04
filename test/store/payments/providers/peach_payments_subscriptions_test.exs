defmodule Store.Payments.Providers.PeachPaymentsSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.PeachPayments

  test "peach payments recurring capability is disabled and unsupported contracts error explicitly" do
    capabilities = PeachPayments.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == false
    assert capabilities.supports_tokenization? == true

    assert {:error, verify_error} = PeachPayments.verify_webhook(%{}, "{}", [])
    assert verify_error.code == "PAYMENT_PROVIDER_VERIFICATION_FAILED"

    assert {:error, normalize_error} = PeachPayments.normalize_webhook(%{})
    assert normalize_error.code == "PAYMENT_PAYLOAD_INVALID"
  end
end
