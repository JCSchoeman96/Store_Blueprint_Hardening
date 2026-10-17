defmodule Store.Orders.InventoryAdmissionRecoveryTest do
  use Store.DataCase, async: false

  alias Store.Catalog.{InventoryItem, StockFastPath}
  alias Store.Orders.InventoryAdmission.{Operation, Request}
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

  test "recovery snapshot preserves reservation absence and current inventory facts" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    operation = operation!(order.id, variant_id, 2, :absent, inventory_facts(variant_id, 4, 0, 1))

    {result, stats} =
      RepoStats.capture(fn -> InventoryReservations.recovery_snapshot(operation) end)

    assert {:ok,
            %{
              reservation: :absent,
              inventory: %{
                variant_id: ^variant_id,
                stock_on_hand: 4,
                reserved_count: 0,
                allow_oversell: false,
                version: 1
              }
            }} = result

    assert stats.query_count == 1
  end

  test "recovery snapshot exposes the complete durable insert evidence" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    now = ~U[2027-02-01 00:00:00.000000Z]

    operation =
      operation!(order.id, variant_id, 2, :absent, inventory_facts(variant_id, 5, 0, 1), now: now)

    assert {:known_commit, _} =
             InventoryReservations.reserve_inventory_outcome(
               order.id,
               [%{variant_id: variant_id, quantity: 2}],
               now: now
             )

    assert {:ok, %{reservation: reservation, inventory: inventory}} =
             InventoryReservations.recovery_snapshot(operation)

    assert reservation.id
    assert reservation.order_id == order.id
    assert reservation.variant_id == variant_id
    assert reservation.reservation_key == operation.reservation_key
    assert reservation.quantity == 2
    assert reservation.state == :active
    assert %DateTime{} = reservation.expires_at
    assert reservation.expires_at == operation.post.reservation.expires_at
    assert reservation.version == 1

    assert inventory == %{
             variant_id: variant_id,
             stock_on_hand: 5,
             reserved_count: 2,
             allow_oversell: false,
             version: 2
           }
  end

  test "recovery snapshot distinguishes PRE and POST for an active same-row adjustment" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 6)
    initial_now = ~U[2027-02-01 00:00:00.000000Z]

    assert {:known_commit, %{reservations: [initial]}} =
             InventoryReservations.reserve_inventory_outcome(
               order.id,
               [
                 %{variant_id: variant_id, quantity: 1}
               ],
               now: initial_now
             )

    initial_facts =
      InventoryReservations.recovery_snapshot(
        operation!(
          order.id,
          variant_id,
          1,
          :absent,
          inventory_facts(variant_id, 6, 0, 1),
          now: initial_now
        )
      )

    assert {:ok, pre} = initial_facts

    operation =
      operation!(
        order.id,
        variant_id,
        3,
        reservation_descriptor(pre.reservation),
        pre.inventory,
        now: ~U[2027-02-01 00:10:00.000000Z]
      )

    assert {:known_commit, %{reservations: [adjusted]}} =
             InventoryReservations.reserve_inventory_outcome(
               order.id,
               [
                 %{variant_id: variant_id, quantity: 3}
               ],
               now: ~U[2027-02-01 00:10:00.000000Z]
             )

    assert {:ok, post} = InventoryReservations.recovery_snapshot(operation)

    assert adjusted.id == initial.id
    assert post.reservation.id == pre.reservation.id
    assert pre.reservation.quantity == 1
    assert post.reservation.quantity == 3
    assert post.reservation.version == pre.reservation.version + 1
    assert post.reservation.expires_at == operation.post.reservation.expires_at
    assert pre.inventory.reserved_count == 1
    assert post.inventory.reserved_count == 3
    assert post.inventory.version == pre.inventory.version + 1
  end

  test "a matching reservation key does not hide mismatching durable facts" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    operation = operation!(order.id, variant_id, 3, :absent, inventory_facts(variant_id, 5, 0, 1))
    expires_at = ~U[2026-01-01 00:00:00.000000Z]

    row =
      insert_reservation!(order.id, variant_id, operation.reservation_key, 1, :cancelled,
        expires_at: expires_at,
        version: 7
      )

    assert {:ok, %{reservation: snapshot}} = InventoryReservations.recovery_snapshot(operation)

    assert snapshot.id == row.id
    assert snapshot.order_id == order.id
    assert snapshot.variant_id == variant_id
    assert snapshot.reservation_key == operation.reservation_key
    assert snapshot.quantity == 1
    assert snapshot.state == :cancelled
    assert snapshot.expires_at == expires_at
    assert snapshot.version == 7
  end

  test "recovery snapshot fails closed when the key belongs to another identity" do
    order = create_order!()
    other_order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    operation = operation!(order.id, variant_id, 1, :absent, inventory_facts(variant_id, 5, 0, 1))
    insert_reservation!(other_order.id, UUIDv7.generate(), operation.reservation_key, 1)

    assert {:error, :contradictory_identity} = InventoryReservations.recovery_snapshot(operation)
  end

  test "recovery snapshot leaves reservation, inventory, and cache state unchanged" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 5)
    operation = operation!(order.id, variant_id, 1, :absent, inventory_facts(variant_id, 5, 0, 1))
    insert_reservation!(order.id, variant_id, operation.reservation_key, 2)

    before_reservation =
      Repo.get_by!(InventoryReservation, reservation_key: operation.reservation_key)

    before_inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    cache_before = StockFastPath.sellable_qty_by_variant_ids([variant_id])

    assert {:ok, _snapshot} = InventoryReservations.recovery_snapshot(operation)

    after_reservation = Repo.get!(InventoryReservation, before_reservation.id)
    after_inventory = Repo.get!(InventoryItem, before_inventory.id)

    assert Map.take(after_reservation, [:quantity, :state, :version]) ==
             Map.take(before_reservation, [:quantity, :state, :version])

    assert Map.take(after_inventory, [:stock_on_hand, :reserved_count, :version]) ==
             Map.take(before_inventory, [:stock_on_hand, :reserved_count, :version])

    assert StockFastPath.sellable_qty_by_variant_ids([variant_id]) == cache_before
  end

  test "recovery snapshot rejects invalid operations before querying the database" do
    {_result, stats} =
      RepoStats.capture(fn ->
        assert {:error, :invalid_operation} = InventoryReservations.recovery_snapshot(nil)
      end)

    assert stats.query_count == 0
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

  defp operation!(order_id, variant_id, quantity, reservation, inventory, opts \\ []) do
    now = Keyword.get(opts, :now, ~U[2027-02-01 00:00:00.000000Z])
    expires_at = DateTime.add(now, 900, :second)
    inventory = Map.new(inventory)

    assert {:ok, request} =
             Request.new(%{
               order_id: order_id,
               variant_id: variant_id,
               quantity: quantity,
               mutation_kind: if(reservation == :absent, do: :reserve, else: :adjust)
             })

    assert {:ok, pre} =
             Operation.Pre.new(%{
               reservation: reservation_descriptor(reservation),
               inventory: inventory
             })

    assert {:ok, post} =
             Operation.Post.new(%{
               reservation:
                 reservation_facts(request.reservation_key, reservation, quantity, expires_at),
               inventory: inventory_post_facts(inventory, reservation, quantity)
             })

    assert {:ok, deadline} =
             Operation.Deadline.new(%{
               db_deadline: 10,
               lease_deadline: 20,
               recovery_deadline: 30,
               safety_margin: 5
             })

    assert {:ok, operation} =
             Operation.new(
               request,
               pre: pre,
               post: post,
               deadline: deadline,
               now: now,
               expires_at: expires_at
             )

    operation
  end

  defp inventory_post_facts(inventory, reservation, quantity) do
    old_quantity = if reservation == :absent, do: 0, else: Map.fetch!(reservation, :quantity)
    delta = quantity - old_quantity
    inventory_version_delta = if delta == 0, do: 0, else: 1

    inventory
    |> Map.put(:reserved_count, inventory.reserved_count + delta)
    |> Map.put(:version, inventory.version + inventory_version_delta)
  end

  defp inventory_facts(variant_id, stock_on_hand, reserved_count, version) do
    %{
      variant_id: variant_id,
      stock_on_hand: stock_on_hand,
      reserved_count: reserved_count,
      allow_oversell: false,
      version: version
    }
  end

  defp reservation_descriptor(:absent), do: :absent

  defp reservation_descriptor(reservation) do
    Map.take(reservation, [
      :id,
      :quantity,
      :state,
      :reservation_key,
      :expires_at,
      :consumed_at,
      :expired_at,
      :cancelled_at,
      :version
    ])
  end

  defp reservation_facts(reservation_key, :absent, quantity, expires_at) do
    %{
      id: nil,
      quantity: quantity,
      state: :active,
      reservation_key: reservation_key,
      expires_at: expires_at,
      version: 1
    }
  end

  defp reservation_facts(reservation_key, reservation, quantity, expires_at) do
    reservation
    |> reservation_descriptor()
    |> Map.put(:reservation_key, reservation_key)
    |> Map.put(:quantity, quantity)
    |> Map.put_new(:state, :active)
    |> Map.put(:expires_at, expires_at)
    |> Map.update(:version, 1, &(&1 + 1))
  end

  defp insert_reservation!(
         order_id,
         variant_id,
         reservation_key,
         quantity,
         state \\ :active,
         opts \\ []
       ) do
    InventoryReservation
    |> struct()
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          order_id: order_id,
          variant_id: variant_id,
          reservation_key: reservation_key,
          quantity: quantity,
          state: state,
          expires_at: Keyword.get(opts, :expires_at, ~U[2026-01-02 00:00:00.000000Z]),
          version: Keyword.get(opts, :version, 1)
        },
        Map.new(Keyword.drop(opts, [:expires_at, :version]))
      )
    )
    |> Repo.insert!()

    Repo.get_by!(InventoryReservation, reservation_key: reservation_key)
  end
end
