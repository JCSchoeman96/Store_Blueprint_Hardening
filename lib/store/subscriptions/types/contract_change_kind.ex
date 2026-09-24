defmodule Store.Subscriptions.Types.ContractChangeKind do
  @moduledoc """
  Supported future subscription contract instructions.
  """

  use Ash.Type.Enum,
    values: [:plan_change, :variant_change, :renew_unchanged]
end
