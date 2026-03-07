defmodule Store.OrderFixtures do
  @moduledoc false

  alias Store.Orders.Order
  alias Store.TestFixtures

  @spec create_customer_order!(keyword()) :: %{user: map(), order: Order.t()}
  def create_customer_order!(opts \\ []) do
    email = Keyword.get(opts, :email, TestFixtures.unique_email("order_customer"))
    order_attrs = opts |> Keyword.get(:order_attrs, %{}) |> Map.new()

    user = TestFixtures.register_user!(email: email)

    order =
      Order
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{user_id: user.id}, Map.drop(order_attrs, [:user_id]))
      )
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    %{user: user, order: order}
  end
end
