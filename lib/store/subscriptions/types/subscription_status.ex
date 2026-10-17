defmodule Store.Subscriptions.Types.SubscriptionStatus do
  @moduledoc """
  Subscription lifecycle states.
  """

  use Ash.Type.Enum,
    values: [:pending, :active, :past_due, :suspended, :canceled, :expired]
end
