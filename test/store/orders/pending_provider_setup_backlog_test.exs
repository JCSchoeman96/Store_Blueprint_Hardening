defmodule Store.Orders.PendingProviderSetupBacklogTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryReservation, Order}
  alias Store.Support.ID.UUIDv7
  alias Store.Workers.ExpirePendingProviderSetupOrdersWorker

  test "backlog snapshot reports counts, ages, and reserved variants" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_started_at = DateTime.add(now, -600, :second)
    fresh_started_at = DateTime.add(now, -120, :second)

    variant_a = UUIDv7.generate()
    variant_b = UUIDv7.generate()

    order_a = create_pending_provider_setup_order!(stale_started_at, variant_a)
    order_b = create_pending_provider_setup_order!(fresh_started_at, variant_b)

    snapshot =
      Store.Orders.pending_provider_setup_backlog_snapshot(now,
        emit_telemetry?: false,
        source: :test
      )

    assert snapshot.count == 2
    assert snapshot.distinct_order_count == 2
    assert snapshot.reserved_variant_count == 2
    assert snapshot.oldest_age_seconds >= 600
    assert snapshot.oldest_age_seconds <= 601
    assert snapshot.newest_age_seconds >= 120
    assert snapshot.newest_age_seconds <= 121

    assert fetch_order!(order_a.id).state == :pending_provider_setup
    assert fetch_order!(order_b.id).state == :pending_provider_setup
  end

  test "stale pending provider setup backlog drains across multiple sweep batches" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started_at = DateTime.add(now, -300, :second)

    variant_ids = Enum.map(1..3, fn _ -> UUIDv7.generate() end)

    orders =
      Enum.map(variant_ids, fn variant_id ->
        create_pending_provider_setup_order!(started_at, variant_id)
      end)

    before_snapshot =
      Store.Orders.pending_provider_setup_backlog_snapshot(now, emit_telemetry?: false)

    assert before_snapshot.count == 3
    assert before_snapshot.reserved_variant_count == 3

    assert {:ok, first_batch} =
             ExpirePendingProviderSetupOrdersWorker.sweep(now,
               ttl_seconds: 60,
               batch_size: 2,
               source: :test
             )

    assert first_batch.swept_count == 2
    assert first_batch.released_count == 2
    assert length(first_batch.order_ids) == 2

    middle_snapshot =
      Store.Orders.pending_provider_setup_backlog_snapshot(now, emit_telemetry?: false)

    assert middle_snapshot.count == 1
    assert middle_snapshot.reserved_variant_count == 1

    assert {:ok, second_batch} =
             ExpirePendingProviderSetupOrdersWorker.sweep(now,
               ttl_seconds: 60,
               batch_size: 2,
               source: :test
             )

    assert second_batch.swept_count == 1
    assert second_batch.released_count == 1
    assert length(second_batch.order_ids) == 1

    final_snapshot =
      Store.Orders.pending_provider_setup_backlog_snapshot(now, emit_telemetry?: false)

    assert final_snapshot.count == 0
    assert final_snapshot.reserved_variant_count == 0

    Enum.each(orders, fn order ->
      cancelled = fetch_order!(order.id)
      assert cancelled.state == :cancelled
      assert is_nil(cancelled.provider_setup_started_at)
    end)
  end

  defp fetch_order!(order_id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^order_id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp create_pending_provider_setup_order!(started_at, variant_id) do
    order = create_order!()
    create_inventory_item!(variant_id, 1)

    assert {:ok, _result} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert {:ok, pending_order} =
             order
             |> Ash.Changeset.for_update(
               :begin_provider_setup,
               %{provider_setup_started_at: started_at},
               context: %{system?: true}
             )
             |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})

    reservation = Repo.get_by!(InventoryReservation, order_id: order.id, variant_id: variant_id)
    assert reservation.state == :active
    assert pending_order.state == :pending_provider_setup
    pending_order
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
