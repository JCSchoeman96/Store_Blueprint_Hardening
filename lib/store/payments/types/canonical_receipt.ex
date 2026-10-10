defmodule Store.Payments.Types.CanonicalReceipt do
  @moduledoc """
  Provider-agnostic normalized webhook receipt payload used by payment workers.
  """

  @enforce_keys [
    :provider,
    :provider_event_id,
    :status,
    :raw_provider_status,
    :amount_minor,
    :currency,
    :provider_environment,
    :occurred_at,
    :event_type
  ]
  defstruct [
    :provider,
    :provider_event_id,
    :provider_session_id,
    :provider_payment_id,
    :provider_idempotency_key,
    :provider_customer_ref,
    :provider_payment_method_ref,
    :local_payment_intent_id,
    :status,
    :raw_provider_status,
    :amount_minor,
    :currency,
    :provider_environment,
    :order_ref,
    :action_url,
    :client_secret,
    :occurred_at,
    :event_type,
    :raw_payload
  ]

  @type status :: :succeeded | :failed | :requires_action | :unknown

  @type t :: %__MODULE__{
          provider: String.t(),
          provider_event_id: String.t(),
          provider_session_id: String.t() | nil,
          provider_payment_id: String.t() | nil,
          provider_idempotency_key: String.t() | nil,
          provider_customer_ref: String.t() | nil,
          provider_payment_method_ref: String.t() | nil,
          local_payment_intent_id: String.t() | nil,
          status: status(),
          raw_provider_status: String.t() | nil,
          amount_minor: non_neg_integer(),
          currency: String.t(),
          provider_environment: String.t() | nil,
          order_ref: String.t() | nil,
          action_url: String.t() | nil,
          client_secret: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          event_type: String.t(),
          raw_payload: map() | nil
        }
end
