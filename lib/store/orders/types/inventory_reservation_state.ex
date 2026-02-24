defmodule Store.Orders.Types.InventoryReservationState do
  @moduledoc """
  Pinned reservation lifecycle states for inventory reservation management.
  """

  use Ash.Type.Enum,
    values: [:active, :consumed, :expired, :cancelled]
end
