defmodule Store.Subscriptions.Types.StoredPaymentMethodStatus do
  @moduledoc """
  Status enum for stored payment methods used by merchant-managed renewals.
  """

  use Ash.Type.Enum, values: [:active, :inactive, :revoked]
end
