defmodule Store.Catalog do
  @moduledoc """
  Catalog domain for inventory resources.
  """

  use Ash.Domain

  resources do
    resource(Store.Catalog.InventoryItem)
  end
end
