defmodule Store.Carts do
  @moduledoc """
  Carts domain for persistent storefront cart state.
  """

  use Ash.Domain

  resources do
    resource(Store.Carts.Cart)
    resource(Store.Carts.CartItem)
  end
end
