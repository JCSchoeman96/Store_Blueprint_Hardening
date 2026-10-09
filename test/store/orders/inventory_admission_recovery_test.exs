defmodule Store.Orders.InventoryAdmissionRecoveryTest do
  use Store.DataCase, async: false

  alias Store.Catalog.{InventoryItem, StockFastPath}
  alias Store.Orders.{InventoryReservation, InventoryReservations, Order}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7
  alias Store.Support.Telemetry.RepoStats

  setup do
    on_exit(fn -> InventoryReservations.in02_clear_reserve_test_hook() end)
    :ok
  end

  test "reserve_inventory_outcome returns known_commit for a successful reservation" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    assert {:known_commit, %{reservations: [reservation], inventory_items: [inventory_item]}} =
             InventoryReservations.reserve_inventory_outcome(order.id, [
               %{variant_id: variant_id, quantity: 2}
             ])

    assert reservation.order_id == order.id
    assert reservation.variant_id == variant_id
    assert reservation.quantity == 2
    assert reservation.state == :active
    assert inventory_item.reserved_count == 2
  end

  test "reserve_inventory_outcome returns known_rollback for governed out-of-stock rejection" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 1)

    assert {:known_rollback, %Error{code: "OUT_OF_STOCK"}} =
             InventoryReservations.reserve_inventory_outcome(order.id, [
               %{variant_id: variant_id, quantity: 2}
             ])

    assert reservation_count(order.id, variant_id) == 0

    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 1
  end

  test "reserve_inventory_outcome returns known_rollback for validation failures before database entry" do
    order = create_order!()

    {_result, stats} =
      RepoStats.capture(fn ->
        assert {:known_rollback, %Error{code: "VALIDATION_ERROR"}} =
                 InventoryReservations.reserve_inventory_outcome(order.id, [
                   %{variant_id: "not-a-uuid", quantity: 1}
                 ])
      end)

    assert stats.query_count == 0
  end

  test "reserve_inventory_outcome propagates unexpected pre-callback ArgumentError" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:pre_callback_argument_error)

    assert_raise ArgumentError, "IN-02 test pre-callback argument error", fn ->
      InventoryReservations.reserve_inventory_outcome(order.id, [
        %{variant_id: variant_id, quantity: 1}
      ])
    end
  end

  test "reserve_inventory_outcome returns known no-commit for proven pre-callback connection failure" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:pre_callback_connection)

    assert {:known_rollback,
            %Error{
              code: "INVENTORY_ADMISSION_UNAVAILABLE",
              meta: %{phase: :before_callback, reason_class: :connection}
            }} =
             InventoryReservations.reserve_inventory_outcome(order.id, [
               %{variant_id: variant_id, quantity: 1}
             ])

    assert reservation_count(order.id, variant_id) == 0
  end

  test "reserve_inventory_outcome classifies post-entry connection uncertainty as ambiguous" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:post_entry_connection)

    outcome =
      InventoryReservations.reserve_inventory_outcome(order.id, [
        %{variant_id: variant_id, quantity: 1}
      ])

    assert {:ambiguous, %{phase: :reservation_transaction, reason_class: :connection}} = outcome
    refute match?({:known_rollback, _}, outcome)
  end

  test "reserve_inventory_outcome classifies post-entry Postgrex uncertainty as database not connection" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:post_entry_postgrex)

    outcome =
      InventoryReservations.reserve_inventory_outcome(order.id, [
        %{variant_id: variant_id, quantity: 1}
      ])

    assert {:ambiguous, %{phase: :reservation_transaction, reason_class: :database}} = outcome
    refute match?({:known_rollback, _}, outcome)
  end

  test "reserve_inventory_outcome classifies post-entry unclassified rollback as ambiguous" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:unclassified_rollback)

    outcome =
      InventoryReservations.reserve_inventory_outcome(order.id, [
        %{variant_id: variant_id, quantity: 1}
      ])

    assert {:ambiguous, %{phase: :reservation_transaction, reason_class: :unclassified}} =
             outcome

    refute match?({:known_rollback, _}, outcome)
  end

  test "legacy reserve_inventory preserves successful public compatibility shape" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 3)

    assert {:ok, %{reservations: [reservation], inventory_items: [_]}} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert reservation.state == :active
  end

  test "legacy reserve_inventory preserves governed public error compatibility" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 1)

    assert {:error, %Error{code: "OUT_OF_STOCK"}} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}])
  end

  test "legacy reserve_inventory maps non-Error rollback tuples through the existing mapper" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:unclassified_rollback)

    assert {:error,
            %Error{code: "RESERVATION_CONFLICT", message: "Reservation transaction failed"}} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])
  end

  test "legacy reserve_inventory still propagates callback exceptions" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    InventoryReservations.in02_put_reserve_test_hook(:legacy_raise)

    assert_raise RuntimeError, "IN-02 legacy reservation exception test", fn ->
      Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])
    end
  end

  test "post-commit invalidation stays outside reserve_inventory_outcome classification" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)

    assert %{^variant_id => 4} = StockFastPath.sellable_qty_by_variant_ids([variant_id])

    assert {:known_commit, _result} =
             InventoryReservations.reserve_inventory_outcome(order.id, [
               %{variant_id: variant_id, quantity: 1}
             ])

    assert %{^variant_id => 4} = StockFastPath.sellable_qty_by_variant_ids([variant_id])

    assert {:ok, _result} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert %{^variant_id => 3} = StockFastPath.sellable_qty_by_variant_ids([variant_id])
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_inventory_item!(variant_id, stock_on_hand) do
    InventoryItem
    |> Ash.Changeset.for_create(:create, %{
      variant_id: variant_id,
      stock_on_hand: stock_on_hand,
      reserved_count: 0
    })
    |> Ash.create!(domain: Store.Catalog, authorize?: false)
  end

  defp reservation_count(order_id, variant_id) do
    InventoryReservation
    |> Ecto.Query.where([r], r.order_id == ^order_id and r.variant_id == ^variant_id)
    |> Repo.aggregate(:count)
  end
end
