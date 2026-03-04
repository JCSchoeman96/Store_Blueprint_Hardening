defmodule Store.Payments.Types.Provider do
  @moduledoc """
  Canonical payment provider enum used for persisted provider identity.
  """

  use Ash.Type.Enum,
    values: [:stripe, :payfast, :paystack, :yoco, :peach_payments]
end
