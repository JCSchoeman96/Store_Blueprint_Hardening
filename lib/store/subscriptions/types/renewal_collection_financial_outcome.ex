defmodule Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
  @moduledoc """
  Provider-verified financial truth for one exact renewal collection.
  """

  use Ash.Type.Enum,
    values: [
      :unresolved,
      :requires_action,
      :verified_success,
      :verified_terminal_financial_non_success
    ]
end
