defmodule Store.Orders.InventoryReservationGenerationTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryAdmission.Request, InventoryReservation, Order}
  alias Store.Support.Errors.Error
  alias Store.Support.ID.UUIDv7
  alias Store.Support.Telemetry.RepoStats

  test "terminal generation history remains after a later generation becomes active" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    generation_a = generation_key(order.id, variant_id)
    generation_b = generation_key(order.id, variant_id, UUIDv7.generate())

    assert {:ok, %{reservation: reservation_a, replayed?: false}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, generation_a, 2)

    assert {:ok, %{reservation: cancelled_a, changed?: true}} =
             Store.Orders.release_exact_generation(order.id, variant_id, generation_a)

    assert cancelled_a.state == :cancelled

    assert {:ok, %{reservation: reservation_b, replayed?: false}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, generation_b, 3)

    assert reservation_b.state == :active
    assert Repo.get!(InventoryReservation, reservation_a.id).state == :cancelled

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, generation_a, 2)

    assert Repo.get!(InventoryReservation, reservation_a.id).state == :cancelled

    history =
      InventoryReservation
      |> where([r], r.order_id == ^order.id and r.variant_id == ^variant_id)
      |> order_by([r], asc: r.reservation_key)
      |> Repo.all()

    assert Enum.map(history, & &1.reservation_key) == Enum.sort([generation_a, generation_b])
    assert length(Enum.uniq(Enum.map(history, & &1.reservation_key))) == 2
    assert Enum.count(history, &(&1.state == :active)) == 1
    assert Repo.get!(InventoryReservation, reservation_a.id).state == :cancelled

    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 3
  end

  test "the partial unique index rejects a second active generation at the database" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    key_a = generation_key(order.id, variant_id)
    key_b = generation_key(order.id, variant_id, UUIDv7.generate())

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key_a, 1)

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key_b, 1)

    assert_raise Ecto.ConstraintError, fn ->
      insert_direct_reservation!(
        order.id,
        variant_id,
        generation_key(order.id, variant_id, UUIDv7.generate()),
        1
      )
    end
  end

  test "generic and renewal reservations cannot both be active for one pair" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    key = generation_key(order.id, variant_id)

    assert {:ok, _generic} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

    assert {:ok, %{released_count: 1}} = Store.Orders.release_reservations_for_order(order.id)
    assert {:ok, _renewal} = Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])
  end

  test "same exact generation concurrency creates one durable row and safely replays" do
    with_committed_fixture(fn order, variant_id ->
      key = generation_key(order.id, variant_id)
      results = concurrently_reserve(order.id, variant_id, [key, key], 2)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.count(results, fn {:ok, result} -> result.replayed? end) == 1
      assert reservation_count(order.id, variant_id) == 1
      assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 2
    end)
  end

  test "different concurrent generations cannot create two active rows" do
    with_committed_fixture(fn order, variant_id ->
      keys = [
        generation_key(order.id, variant_id),
        generation_key(order.id, variant_id, UUIDv7.generate())
      ]

      results = concurrently_reserve(order.id, variant_id, keys, 1)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.count(results, &match?({:error, %Error{code: "RESERVATION_CONFLICT"}}, &1)) ==
               1

      active_count =
        InventoryReservation
        |> where(
          [r],
          r.order_id == ^order.id and r.variant_id == ^variant_id and r.state == :active
        )
        |> Repo.aggregate(:count)

      assert active_count == 1
    end)
  end

  test "exact recovery distinguishes missing, complete, and contradictory evidence" do
    order = create_order!()
    other_order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)

    assert :not_found == Store.Orders.recover_exact_generation(order.id, variant_id, key)

    insert_direct_reservation!(other_order.id, variant_id, key, 1, :cancelled)

    assert {:error, :contradictory_evidence} =
             Store.Orders.recover_exact_generation(order.id, variant_id, key)

    contradictory = Repo.get_by!(InventoryReservation, reservation_key: key)
    Repo.delete!(contradictory)

    assert {:ok, %{reservation: row}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

    assert {:ok, {:found, facts}} =
             Store.Orders.recover_exact_generation(order.id, variant_id, key)

    assert facts.id == row.id
    assert facts.reservation_key == key
    assert facts.order_id == order.id
    assert facts.variant_id == variant_id
    assert facts.quantity == 1
    assert facts.state == :active
    assert is_struct(facts.expires_at, DateTime)
    assert facts.consumed_at == nil
    assert facts.expired_at == nil
    assert facts.cancelled_at == nil
    assert facts.version == row.version
  end

  test "exact release only changes its own historical generation" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 6)
    key_a = generation_key(order.id, variant_id)
    key_b = generation_key(order.id, variant_id, UUIDv7.generate())

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key_a, 2)

    assert {:ok, %{changed?: true}} =
             Store.Orders.release_exact_generation(order.id, variant_id, key_a)

    assert {:ok, %{reservation: active_b}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key_b, 3)

    assert {:ok, %{changed?: false, reservation: cancelled_a}} =
             Store.Orders.release_exact_generation(order.id, variant_id, key_a)

    assert cancelled_a.state == :cancelled
    assert Repo.get!(InventoryReservation, active_b.id).state == :active
    assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 3
  end

  test "exact consume only changes its own historical generation" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    key_a = generation_key(order.id, variant_id)
    key_b = generation_key(order.id, variant_id, UUIDv7.generate())

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key_a, 2)

    assert {:ok, %{changed?: true, reservation: consumed_a}} =
             Store.Orders.consume_exact_generation(order.id, variant_id, key_a)

    assert consumed_a.state == :consumed

    assert {:ok, %{reservation: active_b}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key_b, 3)

    assert {:ok, %{changed?: false, reservation: replayed_a}} =
             Store.Orders.consume_exact_generation(order.id, variant_id, key_a)

    assert replayed_a.state == :consumed
    assert Repo.get!(InventoryReservation, active_b.id).state == :active
    inventory = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory.reserved_count == 3
    assert inventory.stock_on_hand == 6
  end

  test "generic order-wide release and consume ignore renewal generations" do
    order = create_order!()
    consume_order = create_order!()
    renewal_variant = UUIDv7.generate()
    consume_renewal_variant = UUIDv7.generate()
    generic_release_variant = UUIDv7.generate()
    generic_consume_variant = UUIDv7.generate()
    create_inventory_item!(renewal_variant, 4)
    create_inventory_item!(consume_renewal_variant, 4)
    create_inventory_item!(generic_release_variant, 4)
    create_inventory_item!(generic_consume_variant, 4)
    renewal_key = generation_key(order.id, renewal_variant)
    consume_renewal_key = generation_key(consume_order.id, consume_renewal_variant)

    assert {:ok, %{reservation: renewal}} =
             Store.Orders.reserve_exact_generation(order.id, renewal_variant, renewal_key, 1)

    assert {:ok, _generic} =
             Store.Orders.reserve_inventory(order.id, [
               %{variant_id: generic_release_variant, quantity: 1}
             ])

    assert {:ok, %{released_count: 1}} = Store.Orders.release_reservations_for_order(order.id)
    assert Repo.get!(InventoryReservation, renewal.id).state == :active
    assert Repo.get_by!(InventoryItem, variant_id: renewal_variant).reserved_count == 1

    assert {:ok, _generic_again} =
             Store.Orders.reserve_inventory(consume_order.id, [
               %{variant_id: generic_consume_variant, quantity: 1}
             ])

    assert {:ok, %{reservation: consume_renewal}} =
             Store.Orders.reserve_exact_generation(
               consume_order.id,
               consume_renewal_variant,
               consume_renewal_key,
               1
             )

    assert {:ok, %{consumed_count: 1}} =
             Store.Orders.consume_reservations_for_order(consume_order.id)

    assert Repo.get!(InventoryReservation, renewal.id).state == :active
    assert Repo.get!(InventoryReservation, consume_renewal.id).state == :active
    assert Repo.get_by!(InventoryItem, variant_id: renewal_variant).reserved_count == 1
    assert Repo.get_by!(InventoryItem, variant_id: consume_renewal_variant).reserved_count == 1
  end

  test "generic TTL expiry leaves past-due renewal generations active" do
    order = create_order!()
    renewal_variant = UUIDv7.generate()
    generic_variant = UUIDv7.generate()
    create_inventory_item!(renewal_variant, 3)
    create_inventory_item!(generic_variant, 3)
    past_now = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)

    renewal_key = generation_key(order.id, renewal_variant)

    assert {:ok, %{reservation: renewal}} =
             Store.Orders.reserve_exact_generation(order.id, renewal_variant, renewal_key, 1,
               now: past_now,
               ttl_seconds: 1
             )

    assert {:ok, _generic} =
             Store.Orders.reserve_inventory(
               order.id,
               [%{variant_id: generic_variant, quantity: 1}],
               now: past_now,
               ttl_seconds: 1
             )

    assert {:ok, %{expired_count: 1}} =
             Store.Orders.expire_reservations(DateTime.add(past_now, 2, :second))

    assert Repo.get!(InventoryReservation, renewal.id).state == :active
    assert Repo.get_by!(InventoryItem, variant_id: renewal_variant).reserved_count == 1
  end

  test "exact operations reject a key associated with another order or variant" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    other_variant = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_exact_generation(order.id, other_variant, key, 1)

    assert {:error, :invalid_identity} =
             Store.Orders.recover_exact_generation(order.id, other_variant, key)
  end

  test "reservation paths keep fixed operations and bounded enumeration queries" do
    order = create_order!()
    exact_variant = UUIDv7.generate()
    create_inventory_item!(exact_variant, 8)
    exact_key = generation_key(order.id, exact_variant)

    {reserve_result, reserve_stats} =
      RepoStats.capture(fn ->
        Store.Orders.reserve_exact_generation(order.id, exact_variant, exact_key, 2)
      end)

    assert {:ok, %{reservation: reservation_a}} = reserve_result
    assert reserve_stats.query_count == 10

    {_replay_result, replay_stats} =
      RepoStats.capture(fn ->
        Store.Orders.reserve_exact_generation(order.id, exact_variant, exact_key, 2)
      end)

    assert replay_stats.query_count == 4

    {_recovery_result, recovery_stats} =
      RepoStats.capture(fn ->
        Store.Orders.recover_exact_generation(order.id, exact_variant, exact_key)
      end)

    assert recovery_stats.query_count == 1

    {_release_result, release_stats} =
      RepoStats.capture(fn ->
        Store.Orders.release_exact_generation(order.id, exact_variant, exact_key)
      end)

    assert release_stats.query_count == 9

    exact_key_b = generation_key(order.id, exact_variant, UUIDv7.generate())

    assert {:ok, _} =
             Store.Orders.reserve_exact_generation(order.id, exact_variant, exact_key_b, 2)

    {_consume_result, consume_stats} =
      RepoStats.capture(fn ->
        Store.Orders.consume_exact_generation(order.id, exact_variant, exact_key_b)
      end)

    assert consume_stats.query_count == 9
    assert Repo.get!(InventoryReservation, reservation_a.id).state == :cancelled

    release_order = create_order!()
    release_variant = UUIDv7.generate()
    release_variant_b = UUIDv7.generate()
    create_inventory_item!(release_variant, 4)
    create_inventory_item!(release_variant_b, 4)

    {generic_reserve_result, generic_reserve_stats} =
      RepoStats.capture(fn ->
        Store.Orders.reserve_inventory(release_order.id, [
          %{variant_id: release_variant, quantity: 1}
        ])
      end)

    assert {:ok, _} = generic_reserve_result
    assert generic_reserve_stats.query_count == 10

    assert {:ok, _} =
             Store.Orders.reserve_inventory(release_order.id, [
               %{variant_id: release_variant_b, quantity: 1}
             ])

    {generic_release_result, generic_release_stats} =
      RepoStats.capture(fn -> Store.Orders.release_reservations_for_order(release_order.id) end)

    assert {:ok, %{released_count: 2}} = generic_release_result
    assert generic_release_stats.query_count == 9

    consume_order = create_order!()
    generic_consume_variant = UUIDv7.generate()
    generic_consume_variant_b = UUIDv7.generate()
    renewal_consume_variant = UUIDv7.generate()
    create_inventory_item!(generic_consume_variant, 4)
    create_inventory_item!(generic_consume_variant_b, 4)
    create_inventory_item!(renewal_consume_variant, 4)

    assert {:ok, _} =
             Store.Orders.reserve_inventory(consume_order.id, [
               %{variant_id: generic_consume_variant, quantity: 1}
             ])

    assert {:ok, _} =
             Store.Orders.reserve_inventory(consume_order.id, [
               %{variant_id: generic_consume_variant_b, quantity: 1}
             ])

    assert {:ok, _} =
             Store.Orders.reserve_exact_generation(
               consume_order.id,
               renewal_consume_variant,
               generation_key(consume_order.id, renewal_consume_variant),
               1
             )

    {generic_consume_result, generic_consume_stats} =
      RepoStats.capture(fn -> Store.Orders.consume_reservations_for_order(consume_order.id) end)

    assert {:ok, %{consumed_count: 2}} = generic_consume_result
    assert generic_consume_stats.query_count == 10

    expiry_order = create_order!()
    expiry_generic_variant = UUIDv7.generate()
    expiry_generic_variant_b = UUIDv7.generate()
    expiry_renewal_variant = UUIDv7.generate()
    create_inventory_item!(expiry_generic_variant, 4)
    create_inventory_item!(expiry_generic_variant_b, 4)
    create_inventory_item!(expiry_renewal_variant, 4)
    past_now = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Store.Orders.reserve_inventory(
               expiry_order.id,
               [%{variant_id: expiry_generic_variant, quantity: 1}],
               now: past_now,
               ttl_seconds: 1
             )

    assert {:ok, _} =
             Store.Orders.reserve_inventory(
               expiry_order.id,
               [%{variant_id: expiry_generic_variant_b, quantity: 1}],
               now: past_now,
               ttl_seconds: 1
             )

    assert {:ok, _} =
             Store.Orders.reserve_exact_generation(
               expiry_order.id,
               expiry_renewal_variant,
               generation_key(expiry_order.id, expiry_renewal_variant),
               1,
               now: past_now,
               ttl_seconds: 1
             )

    {expiry_result, expiry_stats} =
      RepoStats.capture(fn ->
        Store.Orders.expire_reservations(DateTime.add(past_now, 2, :second))
      end)

    assert {:ok, %{expired_count: 2}} = expiry_result
    assert expiry_stats.query_count == 9
  end

  defp generation_key(order_id, variant_id, generation_id \\ UUIDv7.generate()) do
    collection_id = UUIDv7.generate()

    assert {:ok, request} =
             Request.new_renewal_generation(order_id, variant_id, collection_id, generation_id, 1)

    request.reservation_key
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

  defp with_committed_fixture(fun) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      order = create_order!()
      variant_id = UUIDv7.generate()
      create_inventory_item!(variant_id, 4)

      try do
        fun.(order, variant_id)
      after
        Repo.delete_all(from r in InventoryReservation, where: r.order_id == ^order.id)
        Repo.delete_all(from i in InventoryItem, where: i.variant_id == ^variant_id)
        Repo.delete_all(from o in Order, where: o.id == ^order.id)
      end
    end)
  end

  defp concurrently_reserve(order_id, variant_id, keys, quantity) do
    parent = self()

    tasks =
      Enum.map(keys, fn key ->
        Task.async(fn ->
          reserve_on_independent_connection(
            parent,
            order_id,
            variant_id,
            key,
            quantity
          )
        end)
      end)

    backend_pids = Enum.map(tasks, fn _task -> await_reservation_connection() end)
    assert length(Enum.uniq(backend_pids)) == length(tasks)
    Enum.each(tasks, &send(&1.pid, :reserve))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp reserve_on_independent_connection(parent, order_id, variant_id, key, quantity) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])
      send(parent, {:reservation_connection_ready, self(), backend_pid})

      receive do
        :reserve -> Store.Orders.reserve_exact_generation(order_id, variant_id, key, quantity)
      after
        10_000 -> flunk("timed out waiting to start the concurrent reservation")
      end
    end)
  end

  defp await_reservation_connection do
    receive do
      {:reservation_connection_ready, _pid, backend_pid} -> backend_pid
    after
      10_000 -> flunk("timed out waiting for an independent PostgreSQL connection")
    end
  end

  defp insert_direct_reservation!(order_id, variant_id, key, quantity, state \\ :active) do
    %InventoryReservation{}
    |> Ecto.Changeset.change(%{
      order_id: order_id,
      variant_id: variant_id,
      reservation_key: key,
      quantity: quantity,
      state: state,
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()
  end

  defp reservation_count(order_id, variant_id) do
    InventoryReservation
    |> where([r], r.order_id == ^order_id and r.variant_id == ^variant_id)
    |> Repo.aggregate(:count)
  end
end
