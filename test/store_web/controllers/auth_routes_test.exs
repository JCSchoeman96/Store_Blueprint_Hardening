defmodule StoreWeb.AuthRoutesTest do
  use StoreWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias AshAuthentication.{Info, Strategy}
  alias Store.Accounts.User

  setup :set_swoosh_global

  test "google oauth request and callback routes are mounted", %{conn: conn} do
    conn = get(conn, "/auth/user/google")
    assert conn.status in [302, 303]
    assert [location] = get_resp_header(conn, "location")
    assert String.contains?(location, "accounts.google.com")

    conn = get(recycle(conn), "/auth/user/google/callback")
    assert conn.status in [302, 401]
  end

  test "password register route signs in and sends confirmation email", %{conn: conn} do
    email = unique_email()

    conn =
      post(conn, "/auth/user/password/register", %{
        "user" => %{
          "email" => email,
          "password" => "Password123!",
          "password_confirmation" => "Password123!"
        }
      })

    assert redirected_to(conn) == "/"
    assert get_session(conn, "user_token")
    assert_email_sent(subject: "Confirm your account", to: email)
  end

  test "password sign-in route sets auth session", %{conn: conn} do
    email = unique_email()
    _user = register_user(email)

    conn =
      post(conn, "/auth/user/password/sign_in", %{
        "user" => %{
          "email" => email,
          "password" => "Password123!"
        }
      })

    assert redirected_to(conn) == "/"
    assert get_session(conn, "user_token")
  end

  defp register_user(email) do
    strategy = Info.strategy!(User, :password)

    {:ok, user} =
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

    user
  end

  defp unique_email do
    "auth_#{System.unique_integer([:positive])}@example.com"
  end
end
