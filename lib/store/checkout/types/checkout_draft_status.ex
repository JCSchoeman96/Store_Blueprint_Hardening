defmodule Store.Checkout.Types.CheckoutDraftStatus do
  @moduledoc """
  Checkout draft lifecycle states for Phase 20 handoff.
  """

  use Ash.Type.Enum,
    values: [:open, :consumed, :expired]
end
