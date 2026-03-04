defmodule Store.Subscriptions.Types.AccessOnPastDue do
  @moduledoc """
  Access policy when a subscription is past due.
  """

  use Ash.Type.Enum,
    values: [:keep_during_grace, :remove_immediately]
end
