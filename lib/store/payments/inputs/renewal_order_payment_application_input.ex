defmodule Store.Payments.Inputs.RenewalOrderPaymentApplicationInput do
  @moduledoc "Typed lookup for a renewal Order before its PaymentIntent identity is bound."

  @enforce_keys [:order_id]
  defstruct [:order_id]

  @type t :: %__MODULE__{order_id: Ecto.UUID.t()}
end
