defmodule Store.Payments.Types.PaymentIntentState do
  @moduledoc """
  Pinned payment intent lifecycle states for phase-04 transitions.
  """

  use Ash.Type.Enum,
    values: [:created, :submitted, :succeeded, :failed, :cancelled]
end
