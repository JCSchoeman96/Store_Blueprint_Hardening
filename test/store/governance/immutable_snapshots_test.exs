defmodule Store.Governance.ImmutableSnapshotsTest do
  use Store.DataCase, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem}
  alias Store.TestFixtures

  test "snapshot resources are append-only (no update/destroy actions)" do
    Enum.each([OrderLineItem, OrderAdjustment], fn resource ->
      action_types =
        resource
        |> Info.actions()
        |> Enum.map(& &1.type)

      refute :update in action_types
      refute :destroy in action_types
    end)
  end

  test "customer read visibility is scoped by parent order ownership" do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("snapshot_customer"))

    other_customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("snapshot_other_customer"))

    own_order = create_order!(%{user_id: customer.id, order_ref: "ORDSNAPOWN001"})
    other_order = create_order!(%{user_id: other_customer.id, order_ref: "ORDSNAPOTH001"})

    own_line_item = create_line_item!(own_order, %{line_no: 1, line_total_minor: 2500})
    _other_line_item = create_line_item!(other_order, %{line_no: 1, line_total_minor: 1500})
    own_adjustment = create_adjustment!(own_order, %{sequence_no: 1, amount_minor: -200})
    _other_adjustment = create_adjustment!(other_order, %{sequence_no: 1, amount_minor: 300})

    assert {:ok, line_items} = Ash.read(OrderLineItem, domain: Store.Orders, actor: customer)
    assert Enum.map(line_items, & &1.id) == [own_line_item.id]

    assert {:ok, adjustments} = Ash.read(OrderAdjustment, domain: Store.Orders, actor: customer)
    assert Enum.map(adjustments, & &1.id) == [own_adjustment.id]
  end

  test "admin and support can read snapshot resources across orders" do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("snapshot_admin"))
    support = TestFixtures.register_user!(email: TestFixtures.unique_email("snapshot_support"))

    _admin_role = TestFixtures.assign_role!(admin, :admin)
    _support_role = TestFixtures.assign_role!(support, :support)

    order_a = create_order!(%{order_ref: "ORDSNAPADM001"})
    order_b = create_order!(%{order_ref: "ORDSNAPADM002"})

    line_item_a = create_line_item!(order_a, %{line_no: 1, line_total_minor: 1000})
    line_item_b = create_line_item!(order_b, %{line_no: 1, line_total_minor: 2000})
    adjustment_a = create_adjustment!(order_a, %{sequence_no: 1, amount_minor: -100})
    adjustment_b = create_adjustment!(order_b, %{sequence_no: 1, amount_minor: -200})

    assert {:ok, admin_line_items} = Ash.read(OrderLineItem, domain: Store.Orders, actor: admin)

    assert Enum.sort(Enum.map(admin_line_items, & &1.id)) ==
             Enum.sort([line_item_a.id, line_item_b.id])

    assert {:ok, support_adjustments} =
             Ash.read(OrderAdjustment, domain: Store.Orders, actor: support)

    assert Enum.sort(Enum.map(support_adjustments, & &1.id)) ==
             Enum.sort([adjustment_a.id, adjustment_b.id])
  end

  test "ordering invariants enforce uniqueness per order" do
    order = create_order!(%{order_ref: "ORDSNAPUNQ001"})

    _line_item = create_line_item!(order, %{line_no: 1, line_total_minor: 1000})

    assert {:error, line_error} =
             OrderLineItem
             |> Ash.Changeset.for_create(:create, %{
               order_id: order.id,
               line_no: 1,
               currency: "USD",
               quantity: 1,
               unit_price_minor: 1000,
               line_total_minor: 1000,
               sku_snapshot: "SKU-1000",
               product_title_snapshot: "Duplicate Line",
               discount_allocated_minor: 0,
               net_line_total_minor: 1000
             })
             |> Ash.create(domain: Store.Orders, authorize?: false)

    assert_duplicate_constraint_error!(line_error)

    _adjustment = create_adjustment!(order, %{sequence_no: 1, amount_minor: -100})

    assert {:error, adjustment_error} =
             OrderAdjustment
             |> Ash.Changeset.for_create(:create, %{
               order_id: order.id,
               sequence_no: 1,
               currency: "USD",
               kind: "manual_credit",
               amount_minor: -100,
               reason: "duplicate"
             })
             |> Ash.create(domain: Store.Orders, authorize?: false)

    assert_duplicate_constraint_error!(adjustment_error)
  end

  defp create_order!(attrs) do
    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_line_item!(order, overrides) do
    attrs =
      %{
        order_id: order.id,
        line_no: 1,
        currency: "USD",
        quantity: 1,
        unit_price_minor: 1000,
        line_total_minor: 1000,
        sku_snapshot: "SKU-DEFAULT",
        product_title_snapshot: "Snapshot Line",
        variant_title_snapshot: "Default Variant",
        discount_allocated_minor: 0,
        net_line_total_minor: 1000
      }
      |> Map.merge(overrides)

    OrderLineItem
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_adjustment!(order, overrides) do
    attrs =
      %{
        order_id: order.id,
        sequence_no: 1,
        currency: "USD",
        kind: "manual_credit",
        amount_minor: -100,
        reason: "support_adjustment"
      }
      |> Map.merge(overrides)

    OrderAdjustment
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp assert_duplicate_constraint_error!(error) do
    message = Exception.message(error)

    assert message =~ "already been taken" or
             message =~ "constraint error" or
             message =~ "unique_constraint"
  end
end
