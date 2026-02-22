defmodule Store.Orders do
  @moduledoc """
  Orders domain for lifecycle state-machine resources.
  """

  use Ash.Domain

  resources do
    resource(Store.Orders.Order)
  end
end
