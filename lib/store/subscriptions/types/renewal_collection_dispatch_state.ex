defmodule Store.Subscriptions.Types.RenewalCollectionDispatchState do
  @moduledoc "Dispatch evidence for one renewal collection epoch."

  use Ash.Type.Enum,
    values: [:not_started, :may_have_been_reached, :not_submitted]
end
