defmodule Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
  @moduledoc "Financial outcome for one renewal collection, independent of dispatch."

  use Ash.Type.Enum,
    values: [
      :unresolved,
      :requires_action,
      :verified_success,
      :verified_terminal_financial_non_success
    ]
end
