defmodule Store.Subscriptions.Types.AccessOnCancel do
  @moduledoc """
  Access policy when a subscription is canceled.
  """

  use Ash.Type.Enum,
    values: [:keep_until_period_end, :remove_immediately]
end
