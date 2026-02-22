defmodule StoreWeb.AccountLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.{Info, Plug.Helpers, Strategy}
  alias Store.Accounts.User

  test "redirects unauthenticated users to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/account")
  end

  test "allows authenticated users to access protected LiveView", %{conn: conn} do
    user = signed_in_user(unique_email())

    conn =
      conn
      |> init_test_session(%{})
      |> Helpers.store_in_session(user)

    assert {:ok, _view, html} = live(conn, ~p"/account")
    assert html =~ "Protected account area"
    assert html =~ to_string(user.email)
  end

  defp signed_in_user(email) do
    strategy = Info.strategy!(User, :password)

    {:ok, _registered_user} =
      Strategy.action(
        strategy,
        :register,
        %{
          "email" => email,
          "password" => "Password123!",
          "password_confirmation" => "Password123!"
        },
        []
      )

    {:ok, user} =
      Strategy.action(strategy, :sign_in, %{"email" => email, "password" => "Password123!"}, [])

    user
  end

  defp unique_email do
    "live_#{System.unique_integer([:positive])}@example.com"
  end
end
