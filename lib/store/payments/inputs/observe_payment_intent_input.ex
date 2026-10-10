defmodule Store.Payments.Inputs.ObservePaymentIntentInput do
  @moduledoc "Typed request to read one known provider transaction for a PaymentIntent."

  @enforce_keys [:payment_intent_id]
  defstruct [:payment_intent_id]

  @type t :: %__MODULE__{
          payment_intent_id: Ecto.UUID.t()
        }
end
