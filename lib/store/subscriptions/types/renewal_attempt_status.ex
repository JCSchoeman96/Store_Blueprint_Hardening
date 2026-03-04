defmodule Store.Subscriptions.Types.RenewalAttemptStatus do
  @moduledoc """
  Renewal attempt status.
  """

  use Ash.Type.Enum,
    values: [:pending, :processing, :succeeded, :failed]
end
