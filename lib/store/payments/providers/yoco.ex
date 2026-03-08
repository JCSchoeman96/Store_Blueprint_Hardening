defmodule Store.Payments.Providers.Yoco do
  @moduledoc """
  Yoco provider boundary adapter.

  Yoco recurring capabilities are intentionally disabled by default until
  a provider-specific recurring contract is implemented and tested.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Support.Errors.Error

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: false,
      supports_tokenization?: false,
      supports_merchant_initiated_charges?: false,
      supports_provider_managed_subscriptions?: false,
      webhook_verification_mode: :offline_hmac,
      supports_webhooks?: true
    }
  end

  @impl true
  def create_intent(_attrs, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "yoco intent creation is not implemented yet")}
  end

  @impl true
  def charge_off_session(_attrs, _opts) do
    {:error, Error.new("PAYMENT_PROVIDER_DISABLED", "yoco recurring charges are disabled")}
  end

  @impl true
  def verify_webhook(_headers, _raw_body, _opts) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_VERIFICATION_FAILED",
       "yoco webhook verification is not implemented yet"
     )}
  end

  @impl true
  def normalize_webhook(_payload) do
    {:error,
     Error.new("PAYMENT_PAYLOAD_INVALID", "yoco webhook normalization is not implemented yet")}
  end
end
