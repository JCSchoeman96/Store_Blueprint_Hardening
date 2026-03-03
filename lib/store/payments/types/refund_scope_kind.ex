defmodule Store.Payments.Types.RefundScopeKind do
  @moduledoc """
  Canonical refund scope semantics used for policy-driven side effects.
  """

  use Ash.Type.Enum, values: [:full_refund, :partial_refund, :shipping_refund]
end
