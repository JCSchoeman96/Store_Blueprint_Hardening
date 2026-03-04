defmodule Store.Payments.Providers.PayFastSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.PayFast

  test "payfast recurring capability is fail-closed and unsupported contracts error explicitly" do
    capabilities = PayFast.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == false

    assert {:error, verify_error} = PayFast.verify_webhook(%{}, "{}", [])
    assert verify_error.code == "PAYMENT_PROVIDER_VERIFICATION_FAILED"

    assert {:error, normalize_error} = PayFast.normalize_webhook(%{})
    assert normalize_error.code == "PAYMENT_PAYLOAD_INVALID"
  end
end
