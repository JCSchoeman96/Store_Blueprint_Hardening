defmodule Store.Subscriptions.Types.ContractChangeStatus do
  @moduledoc """
  Durable lifecycle states for a future subscription contract instruction.
  """

  use Ash.Type.Enum,
    values: [:queued, :superseded, :canceled, :bound_to_renewal, :applied]
end
