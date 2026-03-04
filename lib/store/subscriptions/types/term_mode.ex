defmodule Store.Subscriptions.Types.TermMode do
  @moduledoc """
  Subscription term mode.
  """

  use Ash.Type.Enum,
    values: [:until_canceled, :fixed_cycles, :fixed_end_at]
end
