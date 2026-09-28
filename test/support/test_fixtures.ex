defmodule Store.TestFixtures do
  @moduledoc """
  Shared fixtures for auth, role assignment, and audit tests.
  """

  import Ash.Expr
  require Ash.Query

  alias AshAuthentication.{Info, Strategy}
  alias Store.Accounts.User
  alias Store.Admin.RoleAssignment

  @spec unique_email(String.t()) :: String.t()
  def unique_email(prefix \\ "user") do
    "#{prefix}_#{System.unique_integer([:positive])}@example.com"
  end

  @spec register_user!(keyword()) :: User.t()
  def register_user!(opts \\ []) do
    email = Keyword.get(opts, :email, unique_email())
    password = Keyword.get(opts, :password, "Password123!")
    strategy = Info.strategy!(User, :password)

    {:ok, user} =
      Strategy.action(
        strategy,
        :register,
        %{
          "email" => email,
          "password" => password,
          "password_confirmation" => password
        },
        []
      )

    user
  end

  @spec sign_in_user!(String.t(), String.t()) :: map()
  def sign_in_user!(email, password \\ "Password123!") do
    strategy = Info.strategy!(User, :password)

    {:ok, user} =
      Strategy.action(strategy, :sign_in, %{"email" => email, "password" => password}, [])

    user
  end

  @spec assign_role!(map(), atom(), keyword()) :: map()
  def assign_role!(user, role, opts \\ []) do
    assigned_by = Keyword.get(opts, :assigned_by)
    actor = Keyword.get(opts, :actor)
    context = Keyword.get(opts, :context, %{bootstrap?: true, system?: true})
    authorize? = Keyword.get(opts, :authorize?, false)

    attrs = %{user_id: user.id, role: role, assigned_by: assigned_by}

    changeset =
      RoleAssignment
      |> Ash.Changeset.for_create(:assign, attrs, context: context)

    create_opts =
      [domain: Store.Admin, authorize?: authorize?]
      |> maybe_put(:actor, actor)

    Ash.create!(changeset, create_opts)
  end

  @spec role_assignment_count!(map(), atom()) :: non_neg_integer()
  def role_assignment_count!(user, role) do
    RoleAssignment
    |> Ash.Query.filter(expr(user_id == ^user.id and role == ^role))
    |> Ash.count!(domain: Store.Admin, authorize?: false)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
