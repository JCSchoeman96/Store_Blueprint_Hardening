defmodule Store.Payments.ProvidersResolverTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers

  test "normalize_provider maps known providers and fails closed for unknown values" do
    assert Providers.normalize_provider("stripe") == :stripe
    assert Providers.normalize_provider("PAYFAST") == :payfast
    assert Providers.normalize_provider("paystack") == :paystack
    assert Providers.normalize_provider("yoco") == :yoco
    assert Providers.normalize_provider("peach_payments") == :peach_payments
    assert Providers.normalize_provider("bogus") == :unknown
    assert Providers.normalize_provider(nil) == :unknown
  end

  test "adapter fails closed for unsupported providers" do
    assert {:error, error} = Providers.adapter("unknown_provider")
    assert error.code == "PAYMENT_EVENT_UNKNOWN"
  end

  test "capabilities are available for all pinned providers" do
    for provider <- [:stripe, :payfast, :paystack, :yoco, :peach_payments] do
      capabilities = Providers.capabilities(provider)
      assert is_map(capabilities)
      assert Map.has_key?(capabilities, :supports_one_time_checkout?)
      assert Map.has_key?(capabilities, :supports_webhooks?)
      assert Map.has_key?(capabilities, :supports_tokenization?)
      assert Map.has_key?(capabilities, :supports_merchant_initiated_charges?)
      assert Map.has_key?(capabilities, :supports_provider_managed_subscriptions?)
    end
  end

  test "webhook verification fails for unknown providers" do
    assert {:error, error} = Providers.verify_webhook("unknown", %{}, "{}", [])
    assert error.code == "PAYMENT_EVENT_UNKNOWN"
  end
end
