defmodule Store.Entitlements.Types.EntitlementSet do
  @moduledoc """
  Cached entitlement snapshot for one user.
  """

  alias Store.Entitlements.EntitlementGrant

  @enforce_keys [:user_id, :grants, :fetched_at, :expires_at]
  defstruct [:user_id, :grants, :fetched_at, :expires_at]

  @type t :: %__MODULE__{
          user_id: String.t(),
          grants: [EntitlementGrant.t()],
          fetched_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @spec effective_grants(t(), DateTime.t()) :: [EntitlementGrant.t()]
  def effective_grants(%__MODULE__{} = set, as_of) when is_struct(as_of, DateTime) do
    Enum.filter(set.grants, &grant_effective?(&1, as_of))
  end

  @spec has_entitlement?(t(), atom(), String.t() | nil, DateTime.t()) :: boolean()
  def has_entitlement?(%__MODULE__{} = set, kind, scope_key, as_of)
      when is_atom(kind) and (is_binary(scope_key) or is_nil(scope_key)) and
             is_struct(as_of, DateTime) do
    effective_grants(set, as_of)
    |> Enum.any?(fn grant ->
      grant.kind == kind and (is_nil(scope_key) or grant.scope_key == scope_key)
    end)
  end

  @spec next_temporal_boundary(t(), DateTime.t()) :: DateTime.t() | nil
  def next_temporal_boundary(%__MODULE__{} = set, as_of) when is_struct(as_of, DateTime) do
    Enum.reduce(set.grants, nil, fn grant, earliest ->
      case next_boundary_for(grant, as_of) do
        %DateTime{} = boundary ->
          if is_nil(earliest) or DateTime.compare(boundary, earliest) == :lt do
            boundary
          else
            earliest
          end

        nil ->
          earliest
      end
    end)
  end

  defp grant_effective?(%EntitlementGrant{} = grant, as_of) do
    grant.status == :active and is_nil(grant.revoked_at) and
      match?(%DateTime{}, grant.valid_from_at) and
      (is_nil(grant.valid_to_at) or match?(%DateTime{}, grant.valid_to_at)) and
      DateTime.compare(grant.valid_from_at, as_of) != :gt and
      match?(true, is_nil(grant.valid_to_at) or DateTime.compare(grant.valid_to_at, as_of) == :gt)
  end

  defp next_boundary_for(
         %EntitlementGrant{
           status: :active,
           revoked_at: nil,
           valid_from_at: %DateTime{} = valid_from_at,
           valid_to_at: valid_to_at
         },
         as_of
       )
       when is_nil(valid_to_at) or is_struct(valid_to_at, DateTime) do
    cond do
      DateTime.compare(valid_from_at, as_of) == :gt ->
        if is_nil(valid_to_at) or DateTime.compare(valid_to_at, valid_from_at) == :gt do
          valid_from_at
        end

      is_struct(valid_to_at, DateTime) and DateTime.compare(valid_to_at, as_of) == :gt ->
        valid_to_at

      true ->
        nil
    end
  end

  defp next_boundary_for(%EntitlementGrant{}, _as_of), do: nil
end
