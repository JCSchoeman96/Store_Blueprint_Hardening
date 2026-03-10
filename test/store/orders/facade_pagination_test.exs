defmodule Store.Orders.FacadePaginationTest do
  use Store.DataCase, async: false

  alias Store.Orders.Facade, as: OrdersFacade
  alias Store.Orders.Order
  alias Store.Orders.Queries.OrderIndexQuery
  alias Store.TestFixtures

  test "list_orders_for_user uses deterministic keyset pagination" do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("orders_keyset_user"))
    other = TestFixtures.register_user!(email: TestFixtures.unique_email("orders_keyset_other"))

    older_order = create_order!(customer.id)
    middle_order = create_order!(customer.id)
    newest_order = create_order!(customer.id)
    _other_order = create_order!(other.id)

    assert {:ok, first_query} = OrderIndexQuery.new(%{"limit" => "2"})
    assert {:ok, first_page} = OrdersFacade.list_orders_for_user(customer, first_query)

    assert %Ash.Page.Keyset{} = first_page
    assert Enum.map(first_page.results, & &1.id) == [newest_order.id, middle_order.id]
    assert first_page.more?

    after_cursor = List.last(first_page.results).__metadata__.keyset

    assert {:ok, second_query} = OrderIndexQuery.new(%{"limit" => "2", "after" => after_cursor})
    assert {:ok, second_page} = OrdersFacade.list_orders_for_user(customer, second_query)

    assert Enum.map(second_page.results, & &1.id) == [older_order.id]
    refute second_page.more?
  end

  test "list_orders_for_admin uses deterministic keyset pagination across owners" do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("orders_keyset_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    customer_a =
      TestFixtures.register_user!(email: TestFixtures.unique_email("orders_keyset_customer_a"))

    customer_b =
      TestFixtures.register_user!(email: TestFixtures.unique_email("orders_keyset_customer_b"))

    oldest_order = create_order!(customer_a.id)
    middle_order = create_order!(customer_b.id)
    newest_order = create_order!(nil)

    assert {:ok, first_query} = OrderIndexQuery.new(%{"limit" => "2"})
    assert {:ok, first_page} = OrdersFacade.list_orders_for_admin(admin, first_query)

    assert Enum.map(first_page.results, & &1.id) == [newest_order.id, middle_order.id]
    assert first_page.more?

    after_cursor = List.last(first_page.results).__metadata__.keyset

    assert {:ok, second_query} = OrderIndexQuery.new(%{"limit" => "2", "after" => after_cursor})
    assert {:ok, second_page} = OrdersFacade.list_orders_for_admin(admin, second_query)

    assert Enum.map(second_page.results, & &1.id) == [oldest_order.id]
    refute second_page.more?
  end

  defp create_order!(user_id) do
    attrs =
      %{
        order_ref: "ORDP29#{System.unique_integer([:positive])}",
        user_id: user_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end
end
