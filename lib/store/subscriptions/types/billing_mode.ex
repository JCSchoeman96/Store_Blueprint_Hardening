defmodule Store.Subscriptions.Types.BillingMode do
  @moduledoc """
  Subscription billing orchestration mode.
  """

  use Ash.Type.Enum,
    values: [:merchant_managed, :provider_managed]
end
