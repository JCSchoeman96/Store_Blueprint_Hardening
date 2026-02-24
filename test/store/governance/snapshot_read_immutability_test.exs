defmodule Store.Governance.SnapshotReadImmutabilityTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem}
  alias Store.TestFixtures

  test "snapshot read returns stored evidence values without recomputation" do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("snapshot_read_customer"))

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: customer.id, order_ref: "ORDSNAPREAD001"})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    line_item =
      OrderLineItem
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        line_no: 1,
        currency: "USD",
        quantity: 2,
        unit_price_minor: 100,
        line_total_minor: 333,
        sku_snapshot: "SKU-READ-001",
        product_title_snapshot: "Read Snapshot Product",
        variant_title_snapshot: "Variant A",
        discount_allocated_minor: 0,
        net_line_total_minor: 333
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    adjustment =
      OrderAdjustment
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        sequence_no: 1,
        currency: "USD",
        kind: "manual_credit",
        amount_minor: -17,
        reason: "evidence_pin"
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    assert {:ok, [first_line_item]} =
             OrderLineItem
             |> Ash.Query.filter(expr(id == ^line_item.id))
             |> Ash.read(domain: Store.Orders, actor: customer)

    assert first_line_item.line_total_minor == 333
    assert first_line_item.quantity == 2
    assert first_line_item.unit_price_minor == 100

    assert {:ok, [first_adjustment]} =
             OrderAdjustment
             |> Ash.Query.filter(expr(id == ^adjustment.id))
             |> Ash.read(domain: Store.Orders, actor: customer)

    assert first_adjustment.amount_minor == -17

    {:ok, _updated_order} =
      order
      |> Ash.Changeset.for_update(:mark_paid, %{})
      |> Ash.update(domain: Store.Orders, context: %{system?: true}, authorize?: false)

    assert {:ok, [second_line_item]} =
             OrderLineItem
             |> Ash.Query.filter(expr(id == ^line_item.id))
             |> Ash.read(domain: Store.Orders, actor: customer)

    assert second_line_item.line_total_minor == 333
    assert second_line_item.quantity == 2
    assert second_line_item.unit_price_minor == 100

    assert {:ok, [second_adjustment]} =
             OrderAdjustment
             |> Ash.Query.filter(expr(id == ^adjustment.id))
             |> Ash.read(domain: Store.Orders, actor: customer)

    assert second_adjustment.amount_minor == -17
  end
end
