defmodule Store.Payments.Inputs.RenewalPaymentApplicationInput do
  @moduledoc "Typed lookup for the exact payment application of a renewal Order and PaymentIntent."

  @enforce_keys [:order_id, :payment_intent_id]
  defstruct [:order_id, :payment_intent_id]

  @type t :: %__MODULE__{
          order_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t()
        }
end
