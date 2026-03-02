defmodule StoreWeb.OrderApiControllerTest do
  use StoreWeb.ConnCase, async: true

  alias Store.Orders.Order
  alias Store.TestFixtures

  test "returns UNAUTHORIZED when actor is missing", %{conn: conn} do
    conn = get(conn, ~p"/api/orders/#{Ecto.UUID.generate()}")

    assert %{
             "errors" => %{
               "code" => "UNAUTHORIZED",
               "message" => "Authentication required",
               "meta" => %{}
             }
           } = json_response(conn, 401)
  end

  test "returns VALIDATION_ERROR when id is malformed", %{conn: conn} do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("api_order_invalid"))

    conn =
      conn
      |> assign(:current_user, user)
      |> get(~p"/api/orders/not-a-uuid")

    assert %{
             "errors" => %{
               "code" => "VALIDATION_ERROR",
               "message" => "id must be a valid UUID",
               "meta" => %{}
             }
           } = json_response(conn, 400)
  end

  test "returns NOT_FOUND for authenticated actor when order does not exist", %{conn: conn} do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("api_order"))

    conn =
      conn
      |> assign(:current_user, user)
      |> get(~p"/api/orders/#{Ecto.UUID.generate()}")

    assert %{
             "errors" => %{
               "code" => "NOT_FOUND",
               "message" => "Resource not found",
               "meta" => %{}
             }
           } = json_response(conn, 404)
  end

  test "returns order data for owner", %{conn: conn} do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("api_owner"))
    order = create_order_for_user!(user.id)
    order_id = order.id

    conn =
      conn
      |> assign(:current_user, user)
      |> get(~p"/api/orders/#{order.id}")

    assert %{"data" => %{"id" => ^order_id}} = json_response(conn, 200)
  end

  test "returns NOT_FOUND for non-owner order reads", %{conn: conn} do
    owner = TestFixtures.register_user!(email: TestFixtures.unique_email("api_owner_hidden"))
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email("api_other_actor"))
    order = create_order_for_user!(owner.id)

    conn =
      conn
      |> assign(:current_user, actor)
      |> get(~p"/api/orders/#{order.id}")

    assert %{
             "errors" => %{
               "code" => "NOT_FOUND",
               "message" => "Resource not found",
               "meta" => %{}
             }
           } = json_response(conn, 404)
  end

  defp create_order_for_user!(user_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{user_id: user_id})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end
end
