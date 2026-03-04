defmodule Store.Entitlements do
  @moduledoc """
  Entitlements domain for subscription-derived access grants.
  """

  use Ash.Domain

  resources do
    resource(Store.Entitlements.EntitlementGrant)
  end
end
