defmodule Store.Subscriptions.Types.IntervalUnit do
  @moduledoc """
  Supported subscription billing interval units.
  """

  use Ash.Type.Enum,
    values: [:day, :month, :year]
end
