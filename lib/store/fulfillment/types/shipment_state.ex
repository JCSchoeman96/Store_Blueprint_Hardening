defmodule Store.Fulfillment.Types.ShipmentState do
  @moduledoc """
  Pinned shipment lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:created, :in_transit, :delivered, :canceled]
end
