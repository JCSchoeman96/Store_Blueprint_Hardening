defmodule Store.Payments.Types.RenewalCollectionChargeRequest do
  @moduledoc """
  Provider-neutral request contract for one bound renewal collection.

  `internal_collection_identity` identifies the Store collection. The
  `provider_request_reference` is the exact durable identity sent to a provider.
  `provider_credential_ref` is opaque provider credential data. A provider maps
  these fields to its own request format.
  """

  @enforce_keys [
    :internal_collection_identity,
    :provider_request_reference,
    :collection_attempt_id,
    :payment_intent_id,
    :renewal_attempt_id,
    :order_id,
    :subscription_id,
    :amount_minor,
    :currency,
    :renewal_key,
    :provider_customer_ref,
    :provider_credential_ref
  ]
  defstruct [
    :internal_collection_identity,
    :provider_request_reference,
    :collection_attempt_id,
    :payment_intent_id,
    :renewal_attempt_id,
    :order_id,
    :subscription_id,
    :amount_minor,
    :currency,
    :renewal_key,
    :provider_customer_ref,
    :provider_customer_email,
    :provider_credential_ref
  ]

  @type t :: %__MODULE__{
          internal_collection_identity: String.t(),
          provider_request_reference: String.t(),
          collection_attempt_id: String.t(),
          payment_intent_id: String.t(),
          renewal_attempt_id: String.t(),
          order_id: String.t(),
          subscription_id: String.t(),
          amount_minor: pos_integer(),
          currency: String.t(),
          renewal_key: String.t(),
          provider_customer_ref: String.t(),
          provider_customer_email: String.t() | nil,
          provider_credential_ref: String.t()
        }
end
