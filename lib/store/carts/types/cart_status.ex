defmodule Store.Carts.Types.CartStatus do
  @moduledoc """
  Cart lifecycle states for Phase 20.
  """

  use Ash.Type.Enum,
    values: [:active, :abandoned]
end
