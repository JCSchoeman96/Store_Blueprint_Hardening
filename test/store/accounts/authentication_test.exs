defmodule Store.Accounts.AuthenticationTest do
  use Store.DataCase, async: false

  import Swoosh.TestAssertions

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.Plug.Helpers, as: AuthenticationPlugHelpers
  alias Store.Accounts.User

  setup :set_swoosh_global

  test "password strategy can register and sign in" do
    strategy = Info.strategy!(User, :password)
    email = unique_email()

    assert {:ok, user} =
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

    assert to_string(user.email) == email
    assert is_binary(user.__metadata__.token)

    assert {:ok, signed_in_user} =
             Strategy.action(
               strategy,
               :sign_in,
               %{"email" => email, "password" => "Password123!"},
               []
             )

    assert signed_in_user.id == user.id
    assert is_binary(signed_in_user.__metadata__.token)
  end

  test "password reset request sends deterministic test email" do
    strategy = Info.strategy!(User, :password)
    email = unique_email()

    assert {:ok, _user} =
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

    assert_email_sent(subject: "Confirm your account", to: email)
    assert :ok = Strategy.action(strategy, :reset_request, %{"email" => email}, [])
    assert_email_sent(subject: "Reset your password", to: email)
  end

  test "stored session tokens authenticate the user and revocation rejects them" do
    strategy = Info.strategy!(User, :password)
    email = unique_email()

    assert {:ok, user} =
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

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AuthenticationPlugHelpers.store_in_session(user)

    assert conn.private[:plug_session_info] == :renew

    conn =
      conn
      |> AuthenticationPlugHelpers.retrieve_from_session(:store)

    assert conn.assigns.current_user.id == user.id

    conn =
      conn
      |> AuthenticationPlugHelpers.revoke_session_tokens(:store)
      |> AuthenticationPlugHelpers.retrieve_from_session(:store)

    assert is_nil(conn.assigns.current_user)
  end

  test "google strategy is pinned to register_with_google action" do
    google = Info.strategy!(User, :google)

    assert google.register_action_name == :register_with_google
  end

  defp unique_email do
    "user_#{System.unique_integer([:positive])}@example.com"
  end
end
