defmodule Store.Orders.Types.OrderState do
  @moduledoc """
  Pinned order lifecycle states for phase-04 transitions.
  """

  use Ash.Type.Enum,
    values: [
      :pending_payment,
      :pending_provider_setup,
      :paid,
      :payment_failed,
      :cancelled,
      :refunded
    ]
end
