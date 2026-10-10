defmodule Store.Subscriptions.Types.PlanRevisionStatus do
  @moduledoc """
  JC-219 PlanRevision lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:draft, :effective, :retired]
end
