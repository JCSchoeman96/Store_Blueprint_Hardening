defmodule Store.Payments.Types.PaymentIntentPurpose do
  @moduledoc """
  Pinned payment intent purposes for order checkout and setup-only flows.
  """

  use Ash.Type.Enum,
    values: [:order_checkout, :subscription_payment_method_update]
end
