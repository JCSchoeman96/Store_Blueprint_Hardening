defmodule Store.Governance.InventoryReservationsTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryReservation, Order}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7

  test "concurrent reserve for last unit yields one success and one failure" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 1)
    order_a = create_order!()
    order_b = create_order!()
    parent = self()

    task_a =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, parent, self())
        Store.Orders.reserve_inventory(order_a.id, [%{variant_id: variant_id, quantity: 1}])
      end)

    task_b =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, parent, self())
        Store.Orders.reserve_inventory(order_b.id, [%{variant_id: variant_id, quantity: 1}])
      end)

    results = [Task.await(task_a, 5000), Task.await(task_b, 5000)]

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    failure_codes = Enum.map(results, &failure_code/1) |> Enum.reject(&is_nil/1)

    assert success_count == 1
    assert length(failure_codes) == 1
    assert hd(failure_codes) in ["OUT_OF_STOCK", "RESERVATION_CONFLICT"]

    inventory = get_inventory_item!(variant_id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1
  end

  test "idempotent retry for same order and variant does not double reserve" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    order = create_order!()

    assert {:ok, first} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert {:ok, second} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    [first_reservation] = first.reservations
    [second_reservation] = second.reservations

    assert first_reservation.id == second_reservation.id
    assert reservation_count(order.id, variant_id) == 1

    inventory = get_inventory_item!(variant_id)
    assert inventory.reserved_count == 1
  end

  test "quantity adjustment uses delta semantics for same order and variant" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    order = create_order!()

    assert {:ok, _first} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert {:ok, second} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}])

    [updated] = second.reservations

    assert updated.quantity == 2

    inventory = get_inventory_item!(variant_id)
    assert inventory.reserved_count == 2

    assert {:ok, _third} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}])

    inventory_after_noop = get_inventory_item!(variant_id)
    assert inventory_after_noop.reserved_count == 2
  end

  test "expiry releases reserved inventory exactly once" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 2)
    order = create_order!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}],
               now: now,
               ttl_seconds: 1
             )

    assert {:ok, first_expire} = Store.Orders.expire_reservations(DateTime.add(now, 2, :second))
    assert first_expire.expired_count == 1

    reservation = get_reservation!(order.id, variant_id)
    assert reservation.state == :expired

    inventory = get_inventory_item!(variant_id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 2

    assert {:ok, second_expire} = Store.Orders.expire_reservations(DateTime.add(now, 3, :second))
    assert second_expire.expired_count == 0

    inventory_after_replay = get_inventory_item!(variant_id)
    assert inventory_after_replay.reserved_count == 0
  end

  test "consume replay decrements stock exactly once" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    order = create_order!()

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}])

    assert {:ok, first_consume} = Store.Orders.consume_reservations_for_order(order.id)
    assert first_consume.consumed_count == 1

    assert {:ok, replay_consume} = Store.Orders.consume_reservations_for_order(order.id)
    assert replay_consume.consumed_count == 0

    reservation = get_reservation!(order.id, variant_id)
    assert reservation.state == :consumed

    inventory = get_inventory_item!(variant_id)
    assert inventory.stock_on_hand == 3
    assert inventory.reserved_count == 0
  end

  test "release replay restores reserved inventory exactly once" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    order = create_order!()

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}])

    assert {:ok, first_release} = Store.Orders.release_reservations_for_order(order.id)
    assert first_release.released_count == 1

    assert {:ok, replay_release} = Store.Orders.release_reservations_for_order(order.id)
    assert replay_release.released_count == 0

    reservation = get_reservation!(order.id, variant_id)
    assert reservation.state == :cancelled

    inventory = get_inventory_item!(variant_id)
    assert inventory.stock_on_hand == 5
    assert inventory.reserved_count == 0
  end

  test "expired reservation cannot be consumed and does not decrement stock" do
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 2)
    order = create_order!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}],
               now: now,
               ttl_seconds: 1
             )

    assert {:ok, _expired} = Store.Orders.expire_reservations(DateTime.add(now, 2, :second))

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.consume_reservations_for_order(order.id)

    inventory = get_inventory_item!(variant_id)
    assert inventory.stock_on_hand == 2
    assert inventory.reserved_count == 0
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

  defp get_inventory_item!(variant_id) do
    Repo.get_by!(InventoryItem, variant_id: variant_id)
  end

  defp get_reservation!(order_id, variant_id) do
    Repo.get_by!(InventoryReservation, order_id: order_id, variant_id: variant_id)
  end

  defp reservation_count(order_id, variant_id) do
    InventoryReservation
    |> where([r], r.order_id == ^order_id and r.variant_id == ^variant_id)
    |> Repo.aggregate(:count)
  end

  defp failure_code({:error, %Error{code: code}}), do: code
  defp failure_code(_other), do: nil
end
