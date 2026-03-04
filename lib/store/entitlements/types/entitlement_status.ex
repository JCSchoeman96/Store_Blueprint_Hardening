defmodule Store.Entitlements.Types.EntitlementStatus do
  @moduledoc """
  Entitlement lifecycle state.
  """

  use Ash.Type.Enum,
    values: [:active, :revoked, :expired]
end
