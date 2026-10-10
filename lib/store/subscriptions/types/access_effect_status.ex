defmodule Store.Subscriptions.Types.AccessEffectStatus do
  @moduledoc """
  Durable lifecycle states for one Subscription access obligation.
  """

  use Ash.Type.Enum,
    values: [:required, :pending, :applied, :failed_retryable, :superseded]
end
