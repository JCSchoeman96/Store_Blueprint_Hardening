defmodule StoreWeb.AdminLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Store.TestFixtures

  test "redirects unauthenticated users to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
  end

  test "redirects authenticated customer away from admin route", %{conn: conn} do
    user = signed_in_user(TestFixtures.unique_email("customer"))

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
  end

  test "allows super_admin to access admin route", %{conn: conn} do
    super_admin = signed_in_user(TestFixtures.unique_email("super_admin"))
    _role = TestFixtures.assign_role!(super_admin, :super_admin)

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(super_admin)

    assert {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Admin Console"
  end

  defp signed_in_user(email) do
    _registered_user = TestFixtures.register_user!(email: email)
    TestFixtures.sign_in_user!(email)
  end
end
