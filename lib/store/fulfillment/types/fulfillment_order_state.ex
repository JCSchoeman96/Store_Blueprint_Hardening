defmodule Store.Fulfillment.Types.FulfillmentOrderState do
  @moduledoc """
  Pinned fulfillment order lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:pending, :packed, :shipped, :delivered, :canceled]
end
