defmodule Store.Entitlements.Types.EntitlementSet do
  @moduledoc """
  Cached entitlement snapshot for one user.
  """

  alias Store.Entitlements.EntitlementGrant

  @enforce_keys [:user_id, :grants, :scopes_by_kind, :fetched_at, :expires_at]
  defstruct [:user_id, :grants, :scopes_by_kind, :fetched_at, :expires_at]

  @type scopes_by_kind :: %{optional(atom()) => MapSet.t(String.t())}

  @type t :: %__MODULE__{
          user_id: String.t(),
          grants: [EntitlementGrant.t()],
          scopes_by_kind: scopes_by_kind(),
          fetched_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @spec effective_grants(t(), DateTime.t()) :: [EntitlementGrant.t()]
  def effective_grants(%__MODULE__{} = set, now \\ DateTime.utc_now())
      when is_struct(now, DateTime) do
    Enum.filter(set.grants, &grant_effective?(&1, now))
  end

  @spec has_entitlement?(t(), atom(), String.t() | nil, DateTime.t()) :: boolean()
  def has_entitlement?(%__MODULE__{} = set, kind, scope_key \\ nil, now \\ DateTime.utc_now())
      when is_atom(kind) and (is_binary(scope_key) or is_nil(scope_key)) and
             is_struct(now, DateTime) do
    effective_grants(set, now)
    |> Enum.any?(fn grant ->
      grant.kind == kind and (is_nil(scope_key) or grant.scope_key == scope_key)
    end)
  end

  defp grant_effective?(%EntitlementGrant{} = grant, now) do
    grant.status == :active and is_nil(grant.revoked_at) and
      match?(true, is_nil(grant.valid_to_at) or DateTime.compare(grant.valid_to_at, now) == :gt)
  end
end
