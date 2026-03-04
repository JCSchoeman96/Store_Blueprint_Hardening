defmodule Store.Payments.Providers.Paystack do
  @moduledoc """
  Paystack provider boundary adapter.

  Capabilities are conservative by default and explicit gating prevents
  unsupported recurring behavior from being enabled accidentally.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Support.Errors.Error

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: true,
      supports_tokenization?: false,
      supports_merchant_initiated_charges?: false,
      supports_provider_managed_subscriptions?: false,
      webhook_verification_mode: :offline_hmac,
      supports_webhooks?: true
    }
  end

  @impl true
  def create_intent(_attrs, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "paystack intent creation is not implemented yet")}
  end

  @impl true
  def verify_webhook(_headers, _raw_body, _opts) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_VERIFICATION_FAILED",
       "paystack webhook verification is not implemented yet"
     )}
  end

  @impl true
  def normalize_webhook(_payload) do
    {:error,
     Error.new("PAYMENT_PAYLOAD_INVALID", "paystack webhook normalization is not implemented yet")}
  end
end
