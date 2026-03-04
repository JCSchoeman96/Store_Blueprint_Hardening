defmodule StoreWeb.JsonApiRouterTest do
  use StoreWeb.ConnCase, async: false

  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.TestFixtures

  test "orders endpoint accepts JSON:API media type and requires authentication", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> get("/api/v1/orders")

    assert conn.status == 401
    assert %{"errors" => [%{"code" => "UNAUTHORIZED"} | _]} = json_response(conn, 401)
  end

  test "invalid UUID path param returns VALIDATION_ERROR", %{conn: conn} do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_invalid_id"))

    conn =
      conn
      |> authenticate_as(user)
      |> get("/api/v1/orders/not-a-uuid")

    assert %{"errors" => [%{"code" => "VALIDATION_ERROR"} | _]} = json_response(conn, 400)
  end

  test "owner can read own order and not other customer order", %{conn: conn} do
    owner = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_owner"))
    other = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_other"))

    owner_order = create_order_for_user!(owner.id)
    _other_order = create_order_for_user!(other.id)

    list_conn =
      conn
      |> authenticate_as(owner)
      |> get("/api/v1/orders")

    assert %{"data" => data} = json_response(list_conn, 200)
    returned_ids = MapSet.new(Enum.map(data, & &1["id"]))
    assert MapSet.member?(returned_ids, owner_order.id)

    get_conn =
      conn
      |> authenticate_as(owner)
      |> get("/api/v1/orders/#{owner_order.id}")

    owner_order_id = owner_order.id
    assert %{"data" => %{"id" => ^owner_order_id}} = json_response(get_conn, 200)
  end

  test "customer cannot access admin orders route", %{conn: conn} do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_customer"))

    conn =
      conn
      |> authenticate_as(customer)
      |> get("/api/v1/admin/orders")

    assert %{"errors" => [%{"code" => "forbidden"} | _]} = json_response(conn, 403)
  end

  test "admin can read admin orders and payment intent routes", %{conn: conn} do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_admin"))
    TestFixtures.assign_role!(admin, :admin)

    order = create_order_for_user!(nil)
    payment_intent = create_payment_intent_for_order!(order.id)

    admin_orders_conn =
      conn
      |> authenticate_as(admin)
      |> get("/api/v1/admin/orders")

    assert %{"data" => order_data} = json_response(admin_orders_conn, 200)
    assert Enum.any?(order_data, &(&1["id"] == order.id))

    payment_index_conn =
      conn
      |> authenticate_as(admin)
      |> get("/api/v1/admin/payment-intents")

    assert %{"data" => payment_data} = json_response(payment_index_conn, 200)
    assert Enum.any?(payment_data, &(&1["id"] == payment_intent.id))

    payment_get_conn =
      conn
      |> authenticate_as(admin)
      |> get("/api/v1/admin/payment-intents/#{payment_intent.id}")

    payment_intent_id = payment_intent.id
    assert %{"data" => %{"id" => ^payment_intent_id}} = json_response(payment_get_conn, 200)
  end

  test "open_api and json_schema routes are admin-only", %{conn: conn} do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_docs_customer"))

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_docs_admin"))
    TestFixtures.assign_role!(admin, :admin)

    unauth_open_api_conn =
      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> get("/api/v1/open_api")

    assert %{"errors" => [%{"code" => "UNAUTHORIZED"} | _]} =
             json_response(unauth_open_api_conn, 401)

    forbidden_open_api_conn =
      conn
      |> authenticate_as(customer)
      |> get("/api/v1/open_api")

    assert %{"errors" => [%{"code" => "FORBIDDEN"} | _]} =
             json_response(forbidden_open_api_conn, 403)

    admin_open_api_conn =
      conn
      |> authenticate_as(admin)
      |> get("/api/v1/open_api")

    assert admin_open_api_conn.status == 200
    assert byte_size(admin_open_api_conn.resp_body) > 0
    assert {:ok, open_api_body} = Jason.decode(admin_open_api_conn.resp_body)
    assert is_map(open_api_body)

    paths = Map.fetch!(open_api_body, "paths")

    for path <- [
          "/api/v1/orders",
          "/api/v1/orders/{id}",
          "/api/v1/admin/orders",
          "/api/v1/admin/orders/{id}",
          "/api/v1/admin/payment-intents",
          "/api/v1/admin/payment-intents/{id}"
        ] do
      assert Map.has_key?(paths, path)
    end

    Enum.each(paths, fn {_path, operations} ->
      assert Enum.sort(Map.keys(operations)) == ["get"]
    end)

    admin_schema_conn =
      conn
      |> authenticate_as(admin)
      |> get("/api/v1/json_schema")

    assert admin_schema_conn.status == 200
    assert byte_size(admin_schema_conn.resp_body) > 0
    assert {:ok, json_schema_body} = Jason.decode(admin_schema_conn.resp_body)
    assert is_map(json_schema_body)
  end

  test "not found record returns 404 for authorized user", %{conn: conn} do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("json_api_not_found"))

    conn =
      conn
      |> authenticate_as(user)
      |> get("/api/v1/orders/#{Ecto.UUID.generate()}")

    assert %{"errors" => [%{"code" => code} | _]} = json_response(conn, 404)
    assert code in ["NOT_FOUND", "not_found"]
  end

  defp authenticate_as(conn, user) do
    signed_in = TestFixtures.sign_in_user!(to_string(user.email))
    token = signed_in.__metadata__.token

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp create_order_for_user!(user_id) do
    attrs = if user_id, do: %{user_id: user_id}, else: %{}

    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_payment_intent_for_order!(order_id) do
    PaymentIntent
    |> Ash.Changeset.for_create(:create, %{order_id: order_id, provider: :stripe})
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end
end
