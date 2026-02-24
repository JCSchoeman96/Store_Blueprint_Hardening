defmodule StoreWeb.OrderApiControllerTest do
  use StoreWeb.ConnCase, async: true

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
end
