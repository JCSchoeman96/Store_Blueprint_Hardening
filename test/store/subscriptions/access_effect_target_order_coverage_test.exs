defmodule Store.Subscriptions.AccessEffectTargetOrderCoverageTest do
  @moduledoc """
  Six-lane F0.5 coverage inventory. Detailed lane behavior is proven in focused
  lifecycle tests; this module asserts the coverage map stays explicit.
  """

  use ExUnit.Case, async: true

  @lanes %{
    initial_paid_order: :lifecycle_disjoint,
    ordinary_charged_renewal: :producer_a,
    suspended_charged_recovery: :producer_a_generalized,
    failed_payment_suspension: :existing_non_effective_preserved,
    immediate_cancellation: :producer_b,
    scheduled_boundary_cancellation: :existing_non_effective_preserved
  }

  test "ACCESS_TARGET_ORDER_COVERAGE lane inventory is complete" do
    assert map_size(@lanes) == 6
    assert @lanes.ordinary_charged_renewal == :producer_a
    assert @lanes.immediate_cancellation == :producer_b
    assert @lanes.initial_paid_order == :lifecycle_disjoint
  end
end
