defmodule Mix.Tasks.Store.Bootstrap.SuperAdmin do
  @moduledoc """
  Bootstraps a super_admin role assignment for an existing user.
  """

  use Mix.Task

  import Ash.Expr
  require Ash.Query

  alias Store.Accounts.User
  alias Store.Admin.RoleAssignment

  @shortdoc "Bootstrap a super_admin role assignment for an existing user"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    email = email_from_args(args)

    with {:ok, user} <- fetch_user(email),
         {:ok, result} <- ensure_super_admin(user) do
      Mix.shell().info(result)
    else
      {:error, message} when is_binary(message) ->
        Mix.raise(message)

      {:error, error} ->
        Mix.raise("bootstrap failed: #{Exception.message(Ash.Error.to_error_class(error))}")
    end
  end

  defp email_from_args([email | _rest]), do: email

  defp email_from_args([]) do
    System.get_env("STORE_BOOTSTRAP_EMAIL") ||
      Mix.raise("missing email argument. usage: mix store.bootstrap.super_admin user@example.com")
  end

  defp fetch_user(email) do
    User
    |> Ash.Query.filter(expr(email == ^email))
    |> Ash.read_one(domain: Store.Accounts, authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "no user found for #{email}"}
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_super_admin(user) do
    existing_assignment_query =
      RoleAssignment
      |> Ash.Query.filter(expr(user_id == ^user.id and role == :super_admin))

    case Ash.exists(existing_assignment_query, domain: Store.Admin, authorize?: false) do
      {:ok, true} ->
        {:ok, "user #{user.email} already has super_admin role assignment"}

      {:ok, false} ->
        attrs = %{user_id: user.id, role: :super_admin, assigned_by: nil}

        changeset =
          RoleAssignment
          |> Ash.Changeset.for_create(:assign, attrs, context: %{bootstrap?: true, system?: true})

        case Ash.create(changeset, domain: Store.Admin, authorize?: false) do
          {:ok, _assignment} -> {:ok, "bootstrapped super_admin for #{user.email}"}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
