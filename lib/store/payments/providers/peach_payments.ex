defmodule Store.Payments.Providers.PeachPayments do
  @moduledoc """
  Peach Payments provider boundary adapter.

  Phase 26 exposes capability contracts and explicit unsupported operation
  errors to keep recurring mode gating fail-closed.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Support.Errors.Error

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: true,
      supports_tokenization?: true,
      supports_merchant_initiated_charges?: true,
      supports_provider_managed_subscriptions?: false,
      webhook_verification_mode: :offline_hmac,
      supports_webhooks?: true
    }
  end

  @impl true
  def create_intent(_attrs, _opts) do
    {:error,
     Error.new("VALIDATION_ERROR", "peach payments intent creation is not implemented yet")}
  end

  @impl true
  def verify_webhook(_headers, _raw_body, _opts) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_VERIFICATION_FAILED",
       "peach payments webhook verification is not implemented yet"
     )}
  end

  @impl true
  def normalize_webhook(_payload) do
    {:error,
     Error.new(
       "PAYMENT_PAYLOAD_INVALID",
       "peach payments webhook normalization is not implemented yet"
     )}
  end
end
