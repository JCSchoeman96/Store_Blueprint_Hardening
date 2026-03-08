defmodule Store.Payments.Providers.Behaviour do
  @moduledoc """
  Contract for payment-provider adapters.

  Adapters are boundary-only modules: they build/verify/normalize provider payloads
  and must not perform DB writes or domain state transitions.
  """

  alias Store.Payments.Types.CanonicalReceipt

  @type capability_map :: %{
          optional(:supports_one_time_checkout?) => boolean(),
          optional(:supports_refunds?) => boolean(),
          optional(:supports_partial_refunds?) => boolean(),
          optional(:supports_tokenization?) => boolean(),
          optional(:supports_merchant_initiated_charges?) => boolean(),
          optional(:supports_provider_managed_subscriptions?) => boolean(),
          optional(:webhook_verification_mode) =>
            :offline_hmac | :remote_verify | :ip_allowlist_plus_signature,
          optional(:supports_webhooks?) => boolean()
        }

  @callback capabilities() :: capability_map()

  @callback create_intent(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @callback charge_off_session(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @callback verify_webhook(map(), binary(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback normalize_webhook(map()) :: {:ok, CanonicalReceipt.t()} | {:error, term()}
end
