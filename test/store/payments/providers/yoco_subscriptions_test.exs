defmodule Store.Payments.Providers.YocoSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers.Yoco

  test "yoco recurring capability is disabled and unsupported contracts error explicitly" do
    capabilities = Yoco.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == false
    assert capabilities.supports_tokenization? == false

    assert {:error, verify_error} = Yoco.verify_webhook(%{}, "{}", [])
    assert verify_error.code == "PAYMENT_PROVIDER_VERIFICATION_FAILED"

    assert {:error, normalize_error} = Yoco.normalize_webhook(%{})
    assert normalize_error.code == "PAYMENT_PAYLOAD_INVALID"
  end
end
