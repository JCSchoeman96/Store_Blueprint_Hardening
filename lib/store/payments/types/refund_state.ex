defmodule Store.Payments.Types.RefundState do
  @moduledoc """
  Pinned refund lifecycle states for phase-12 semantics.
  """

  use Ash.Type.Enum,
    values: [:requested, :submitted, :succeeded, :failed, :cancelled]
end
