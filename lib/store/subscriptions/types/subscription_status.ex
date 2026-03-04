defmodule Store.Subscriptions.Types.SubscriptionStatus do
  @moduledoc """
  Subscription lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:pending, :active, :past_due, :canceled, :expired]
end
