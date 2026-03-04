defmodule Store.Subscriptions.Types.AnchorMode do
  @moduledoc """
  Subscription billing anchor mode.
  """

  use Ash.Type.Enum,
    values: [:start_anniversary, :fixed_day_of_month]
end
