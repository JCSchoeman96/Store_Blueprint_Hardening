defmodule Store.Subscriptions.Types.AccessDisposition do
  @moduledoc """
  Desired access outcome recorded by a Subscription AccessEffect.
  """

  use Ash.Type.Enum,
    values: [:effective, :non_effective]
end
