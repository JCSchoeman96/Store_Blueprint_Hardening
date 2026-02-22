defmodule Store.Governance.AccountsPolicyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias AshAuthentication.{Info, Strategy}
  alias Store.Accounts.User

  test "user reads are scoped to actor own-data only" do
    actor = register_user(unique_email())
    other = register_user(unique_email())

    own_query = Ash.Query.filter(User, expr(id == ^actor.id))
    other_query = Ash.Query.filter(User, expr(id == ^other.id))

    assert {:ok, [own_result]} = Ash.read(own_query, actor: actor)
    assert own_result.id == actor.id

    assert {:ok, []} = Ash.read(other_query, actor: actor)
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
    "policy_#{System.unique_integer([:positive])}@example.com"
  end
end
