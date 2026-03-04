defmodule Store.Entitlements.Types.EntitlementSourceKind do
  @moduledoc """
  Entitlement source kind.
  """

  use Ash.Type.Enum,
    values: [:subscription]
end
