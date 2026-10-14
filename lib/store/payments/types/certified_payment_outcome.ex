defmodule Store.Payments.Types.CertifiedPaymentOutcome do
  @moduledoc false

  use Ash.Type.Enum,
    values: [
      :requires_action,
      :verified_success,
      :verified_terminal_financial_non_success
    ]
end
