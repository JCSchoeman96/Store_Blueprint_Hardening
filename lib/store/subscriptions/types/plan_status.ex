defmodule Store.Subscriptions.Types.PlanStatus do
  @moduledoc """
  Subscription plan lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:active, :archived]
end
