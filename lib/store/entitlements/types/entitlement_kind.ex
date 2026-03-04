defmodule Store.Entitlements.Types.EntitlementKind do
  @moduledoc """
  Entitlement grant kind.
  """

  use Ash.Type.Enum,
    values: [:membership_access, :digital_library, :discount_tier]
end
