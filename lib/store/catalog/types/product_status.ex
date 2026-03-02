defmodule Store.Catalog.Types.ProductStatus do
  @moduledoc """
  Catalog product lifecycle states for storefront visibility and admin transitions.
  """

  use Ash.Type.Enum,
    values: [:draft, :published, :archived]
end
