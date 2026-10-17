defmodule Store.Payments.Inputs.RenewalCancellationRemediationInput do
  @moduledoc "Typed request to create a full refund intent for an exact canceled renewal collection."

  @enforce_keys [:renewal_attempt_id, :order_id, :payment_intent_id]
  defstruct [:renewal_attempt_id, :order_id, :payment_intent_id]

  @type t :: %__MODULE__{
          renewal_attempt_id: Ecto.UUID.t(),
          order_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t()
        }
end
