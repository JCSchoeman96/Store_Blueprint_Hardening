defmodule Store.Workers.ExpireInventoryReservationsWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryReservation, Order}
  alias Store.Support.ID.UUIDv7
  alias Store.Workers.ExpireInventoryReservationsWorker

  test "worker expires active past-due reservations and releases reserved_count" do
    variant_id = UUIDv7.generate()
    order = create_order!()
    create_inventory_item!(variant_id, 3)

    past_now = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 2}],
               now: past_now,
               ttl_seconds: 1
             )

    assert :ok = perform_job(ExpireInventoryReservationsWorker, %{})

    reservation = Repo.get_by!(InventoryReservation, order_id: order.id, variant_id: variant_id)
    assert reservation.state == :expired

    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 0
    assert inventory.stock_on_hand == 3
  end

  test "expired holds no longer block subsequent reservation attempts" do
    variant_id = UUIDv7.generate()
    first_order = create_order!()
    second_order = create_order!()
    create_inventory_item!(variant_id, 1)

    past_now = DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, _reserved} =
             Store.Orders.reserve_inventory(
               first_order.id,
               [%{variant_id: variant_id, quantity: 1}],
               now: past_now,
               ttl_seconds: 1
             )

    assert :ok = perform_job(ExpireInventoryReservationsWorker, %{})

    assert {:ok, second_reserve} =
             Store.Orders.reserve_inventory(second_order.id, [
               %{variant_id: variant_id, quantity: 1}
             ])

    assert length(second_reserve.reservations) == 1

    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 1
    assert inventory.stock_on_hand == 1
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
end
