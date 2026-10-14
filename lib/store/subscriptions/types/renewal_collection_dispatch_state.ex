defmodule Store.Subscriptions.Types.RenewalCollectionDispatchState do
  @moduledoc """
  Durable evidence about whether a provider may have received a collection request.
  """

  use Ash.Type.Enum,
    values: [:not_started, :may_have_been_reached, :not_submitted]
end
