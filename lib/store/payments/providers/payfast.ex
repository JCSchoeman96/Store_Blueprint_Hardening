defmodule Store.Payments.Providers.PayFast do
  @moduledoc """
  PayFast provider boundary adapter.

  Phase 26 exposes capabilities and explicit unsupported operation errors while
  recurring-specific orchestration is implemented in domain workers.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Support.Errors.Error

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: false,
      supports_tokenization?: true,
      supports_merchant_initiated_charges?: true,
      supports_provider_managed_subscriptions?: false,
      webhook_verification_mode: :ip_allowlist_plus_signature,
      supports_webhooks?: true
    }
  end

  @impl true
  def create_intent(_attrs, _opts) do
    {:error, Error.new("VALIDATION_ERROR", "payfast intent creation is not implemented yet")}
  end

  @impl true
  def charge_off_session(_attrs, _opts) do
    {:error, Error.new("PAYMENT_PROVIDER_DISABLED", "payfast recurring charges are disabled")}
  end

  @impl true
  def verify_webhook(_headers, _raw_body, _opts) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_VERIFICATION_FAILED",
       "payfast webhook verification is not implemented yet"
     )}
  end

  @impl true
  def normalize_webhook(_payload) do
    {:error,
     Error.new("PAYMENT_PAYLOAD_INVALID", "payfast webhook normalization is not implemented yet")}
  end
end
