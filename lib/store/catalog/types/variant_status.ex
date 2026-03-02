defmodule Store.Catalog.Types.VariantStatus do
  @moduledoc """
  Variant lifecycle states for catalog sellable records.
  """

  use Ash.Type.Enum,
    values: [:active, :archived]
end
