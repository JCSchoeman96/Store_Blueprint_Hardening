defmodule Store.Admin.Authorization do
  @moduledoc """
  Role membership checks backed by RoleAssignment.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.RoleAssignment

  @spec has_any_role?(map() | nil, [atom()]) :: boolean()
  def has_any_role?(nil, _roles), do: false

  def has_any_role?(actor, roles) when is_list(roles) do
    with actor_id when not is_nil(actor_id) <- actor_id(actor),
         true <- roles != [],
         {:ok, assignments} <- fetch_assignments(actor_id) do
      allowed_roles = MapSet.new(roles ++ Enum.map(roles, &to_string/1))
      Enum.any?(assignments, &matches_role?(&1, allowed_roles))
    else
      _ -> false
    end
  end

  defp fetch_assignments(actor_id) do
    RoleAssignment
    |> Ash.Query.filter(expr(user_id == ^actor_id))
    |> Ash.read(domain: Store.Admin, authorize?: false)
  end

  defp matches_role?(assignment, allowed_roles) do
    MapSet.member?(allowed_roles, assignment.role) ||
      MapSet.member?(allowed_roles, to_string(assignment.role))
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil
end
