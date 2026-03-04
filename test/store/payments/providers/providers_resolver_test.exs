defmodule Store.Payments.ProvidersResolverTest do
  use ExUnit.Case, async: false

  alias Store.Payments.Providers

  setup do
    previous = Application.get_env(:store, :payments, [])

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

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
    assert error.code == "PAYMENT_PROVIDER_UNSUPPORTED"
    refute error.code == unknown_event_code()
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
    assert error.code == "PAYMENT_PROVIDER_UNSUPPORTED"
    refute error.code == unknown_event_code()
  end

  test "normalize_enabled_providers parses aliases and deduplicates deterministically" do
    assert {:ok, [:peach_payments, :payfast]} =
             Providers.normalize_enabled_providers("peach, payfast, PEACH_PAYMENTS")
  end

  test "ensure_enabled_provider is fail-closed for providers not in enabled list" do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe, :payfast],
      default_purchase_provider_for_ui: :stripe
    )

    assert :ok = Providers.ensure_enabled_provider(:stripe)

    assert {:error, error} = Providers.ensure_enabled_provider(:yoco)
    assert error.code == "PAYMENT_PROVIDER_DISABLED"
    assert error.meta.provider == "yoco"
  end

  defp unknown_event_code do
    [:payment, :event, :unknown]
    |> Enum.map_join("_", fn part ->
      part
      |> Atom.to_string()
      |> String.upcase()
    end)
  end
end
