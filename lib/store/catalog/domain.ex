defmodule Store.Catalog do
  @moduledoc """
  Catalog domain for products, variants, categories, images, and inventory.
  """

  use Ash.Domain

  resources do
    resource(Store.Catalog.Category)
    resource(Store.Catalog.Product)
    resource(Store.Catalog.ProductOption)
    resource(Store.Catalog.ProductOptionValue)
    resource(Store.Catalog.Variant)
    resource(Store.Catalog.VariantOptionSelection)
    resource(Store.Catalog.ProductImage)
    resource(Store.Catalog.InventoryItem)
  end
end
