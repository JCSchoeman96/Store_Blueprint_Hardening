defmodule Store.Orders.InventoryReservationGenerationTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Catalog.InventoryItem
  alias Store.Orders.{InventoryAdmission.Request, InventoryReservation, Order}
  alias Store.Support.AshNotifications
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

  test "zero quantity exact reserve does not create an active generation row" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    key = generation_key(order.id, variant_id)

    assert {:error, %Error{code: "RESERVATION_CONFLICT"}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key, 0)

    assert reservation_count(order.id, variant_id) == 0
    assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0

    assert {:ok, %{reservation: %{state: :active}}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)
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

  test "generic consume fails closed if a selected reservation turns terminal before its lock" do
    with_committed_fixture(fn order, variant_id ->
      assert {:ok, _} =
               Store.Orders.reserve_inventory(order.id, [%{variant_id: variant_id, quantity: 1}])

      parent = self()

      lock_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from item in InventoryItem,
                  where: item.variant_id == ^variant_id,
                  lock: "FOR UPDATE"
              )

              send(parent, :inventory_item_locked)

              receive do
                :release_inventory -> Store.Orders.release_reservations_for_order(order.id)
              after
                10_000 -> Repo.rollback(:timed_out_waiting_to_release_inventory)
              end
            end)
          end)
        end)

      assert_receive :inventory_item_locked, 10_000

      handler_id = "reservation_generation_consume_race_#{System.unique_integer([:positive])}"
      query_ref = make_ref()

      :ok =
        :telemetry.attach(
          handler_id,
          [:store, :repo, :query],
          fn _event, _measurements, metadata, {test_pid, ref} ->
            query = metadata[:query]
            normalized_query = if is_binary(query), do: String.upcase(query), else: ""

            if String.contains?(normalized_query, "FROM \"INVENTORY_RESERVATIONS\"") and
                 String.contains?(normalized_query, "ORDER BY") and
                 not String.contains?(normalized_query, "FOR UPDATE") do
              send(test_pid, {:generic_reservation_candidates_selected, ref})
            end
          end,
          {parent, query_ref}
        )

      consume_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            Store.Orders.consume_reservations_for_order(order.id)
          end)
        end)

      try do
        assert_receive {:generic_reservation_candidates_selected, ^query_ref}, 10_000
        send(lock_task.pid, :release_inventory)
        assert {:error, %Error{code: "RESERVATION_CONFLICT"}} = Task.await(consume_task, 10_000)
        assert {:ok, _release_result} = Task.await(lock_task, 10_000)

        reservation =
          Repo.get_by!(InventoryReservation, order_id: order.id, variant_id: variant_id)

        assert reservation.state == :cancelled
        assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0
      after
        send(lock_task.pid, :release_inventory)
        :telemetry.detach(handler_id)
      end
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

    assert {:error, :invalid_identity} =
             Store.Orders.reserve_exact_generation(order.id, other_variant, key, 1)

    assert {:error, :invalid_identity} =
             Store.Orders.recover_exact_generation(order.id, other_variant, key)

    assert {:error, :invalid_identity} =
             Store.Orders.release_exact_generation(order.id, other_variant, key)

    assert {:error, :invalid_identity} =
             Store.Orders.consume_exact_generation(order.id, other_variant, key)

    assert reservation_count(order.id, variant_id) == 0
    assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0
  end

  test "exact reserve reports a database lock timeout as an ambiguous outcome" do
    with_committed_fixture(fn order, variant_id ->
      key = generation_key(order.id, variant_id)

      result =
        with_inventory_item_locked(variant_id, fn ->
          Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)
        end)

      assert {:error, :ambiguous_database_outcome} = result
      refute match?({:error, %Error{code: "RESERVATION_CONFLICT"}}, result)
      assert :not_found == Store.Orders.recover_exact_generation(order.id, variant_id, key)
      assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0
    end)
  end

  test "exact release and consume report database lock timeouts as ambiguous outcomes" do
    with_committed_fixture(fn order, variant_id ->
      key = generation_key(order.id, variant_id)

      assert {:ok, %{reservation: %{state: :active}}} =
               Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

      release_result =
        with_inventory_item_locked(variant_id, fn ->
          Store.Orders.release_exact_generation(order.id, variant_id, key)
        end)

      assert {:error, :ambiguous_database_outcome} = release_result
      refute match?({:error, %Error{code: "RESERVATION_CONFLICT"}}, release_result)

      assert {:ok, {:found, %{state: :active}}} =
               Store.Orders.recover_exact_generation(order.id, variant_id, key)

      consume_result =
        with_inventory_item_locked(variant_id, fn ->
          Store.Orders.consume_exact_generation(order.id, variant_id, key)
        end)

      assert {:error, :ambiguous_database_outcome} = consume_result
      refute match?({:error, %Error{code: "RESERVATION_CONFLICT"}}, consume_result)

      assert {:ok, {:found, %{state: :active}}} =
               Store.Orders.recover_exact_generation(order.id, variant_id, key)

      assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 1
    end)
  end

  test "failed committed fixture setup leaves no partial fixture rows" do
    parent = self()

    assert_raise RuntimeError, "injected fixture setup failure", fn ->
      create_committed_fixture!(fn order, variant_id ->
        send(parent, {:partial_fixture_identity, order.id, variant_id})
        raise "injected fixture setup failure"
      end)
    end

    assert_receive {:partial_fixture_identity, order_id, variant_id}

    try do
      {order_exists?, inventory_item_exists?, reservation_count} =
        Sandbox.unboxed_run(Store.Repo, fn ->
          order_exists? = Repo.exists?(from o in Order, where: o.id == ^order_id)

          inventory_item_exists? =
            Repo.exists?(from i in InventoryItem, where: i.variant_id == ^variant_id)

          reservation_count =
            Repo.aggregate(
              from(r in InventoryReservation, where: r.order_id == ^order_id),
              :count,
              :id
            )

          {order_exists?, inventory_item_exists?, reservation_count}
        end)

      refute order_exists?, "failed setup left its committed Order visible"
      refute inventory_item_exists?, "failed setup left its InventoryItem visible"
      assert reservation_count == 0
    after
      Sandbox.unboxed_run(Store.Repo, fn ->
        Repo.delete_all(from r in InventoryReservation, where: r.order_id == ^order_id)
        Repo.delete_all(from i in InventoryItem, where: i.variant_id == ^variant_id)
        Repo.delete_all(from o in Order, where: o.id == ^order_id)
      end)
    end
  end

  test "post-commit fixture failure runs durable cleanup before returning" do
    parent = self()

    assert_raise RuntimeError, "injected post-commit fixture failure", fn ->
      with_committed_fixture(
        fn _order, _variant_id -> flunk("fixture body must not run after setup failure") end,
        after_commit: fn order, variant_id ->
          send(parent, {:post_commit_fixture_identity, order.id, variant_id})
          raise "injected post-commit fixture failure"
        end
      )
    end

    assert_receive {:post_commit_fixture_identity, order_id, variant_id}

    {order_exists?, inventory_item_exists?, reservation_count} =
      Sandbox.unboxed_run(Store.Repo, fn ->
        order_exists? = Repo.exists?(from o in Order, where: o.id == ^order_id)

        inventory_item_exists? =
          Repo.exists?(from i in InventoryItem, where: i.variant_id == ^variant_id)

        reservation_count =
          Repo.aggregate(
            from(r in InventoryReservation, where: r.order_id == ^order_id),
            :count,
            :id
          )

        {order_exists?, inventory_item_exists?, reservation_count}
      end)

    refute order_exists?
    refute inventory_item_exists?
    assert reservation_count == 0
  end

  test "guard_exact_generation rejects malformed public arguments without raising" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    key = generation_key(order.id, variant_id)

    assert {:error, :invalid_identity} =
             Store.Orders.guard_exact_generation(order.id, variant_id, key, 0)

    assert {:error, :invalid_identity} =
             Store.Orders.guard_exact_generation(order.id, variant_id, key, "1")

    assert {:error, :invalid_identity} =
             Store.Orders.guard_exact_generation(nil, variant_id, key, 1)

    assert {:error, :invalid_identity} =
             Store.Orders.guard_exact_generation(order.id, nil, key, 1)

    assert {:error, :invalid_identity} =
             Store.Orders.guard_exact_generation(order.id, variant_id, nil, 1)
  end

  test "guard_exact_generation requires an outer caller transaction" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key, 2)

    assert {:error, :transaction_required} =
             Store.Orders.guard_exact_generation(order.id, variant_id, key, 2)
  end

  test "guard_exact_generation returns active generation facts inside caller transaction" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)

    assert {:ok, %{reservation: reservation}} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, key, 2)

    inventory_before = Repo.get_by!(InventoryItem, variant_id: variant_id)

    assert {:ok, {:ok, facts}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, key, 2)
             end)

    assert facts.id == reservation.id
    assert facts.reservation_key == key
    assert facts.order_id == order.id
    assert facts.variant_id == variant_id
    assert facts.quantity == 2
    assert facts.state == :active
    assert Repo.get!(InventoryReservation, reservation.id).state == :active

    inventory_after = Repo.get_by!(InventoryItem, variant_id: variant_id)
    assert inventory_after.reserved_count == inventory_before.reserved_count
    assert inventory_after.stock_on_hand == inventory_before.stock_on_hand
  end

  test "guard_exact_generation performs one reservation FOR UPDATE lookup and no inventory queries" do
    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

    handler_id = "guard_exact_generation_query_shape_#{System.unique_integer([:positive])}"
    queries = :ets.new(:guard_queries, [:bag, :private])

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, table ->
          query = metadata[:query]

          if is_binary(query) do
            :ets.insert(table, {System.unique_integer(), String.upcase(query)})
          end
        end,
        queries
      )

    try do
      assert {:ok, {guard_result, guard_stats}} =
               Repo.transaction(fn ->
                 RepoStats.capture(fn ->
                   Store.Orders.guard_exact_generation(order.id, variant_id, key, 1)
                 end)
               end)

      assert {:ok, %{state: :active}} = guard_result
      assert guard_stats.query_count == 1

      captured =
        :ets.tab2list(queries)
        |> Enum.map(fn {_id, query} -> query end)

      data_queries =
        Enum.reject(captured, fn query -> query in ["BEGIN", "COMMIT", "ROLLBACK"] end)

      reservation_selects =
        Enum.filter(data_queries, fn query ->
          String.contains?(query, "INVENTORY_RESERVATIONS") and
            String.contains?(query, "FOR UPDATE")
        end)

      assert length(reservation_selects) == 1
      [only_query] = reservation_selects
      refute String.contains?(only_query, "INVENTORY_ITEMS")
      assert String.contains?(only_query, "RESERVATION_KEY")
      refute Enum.any?(data_queries, &String.starts_with?(&1, "INSERT "))
      refute Enum.any?(data_queries, &String.starts_with?(&1, "UPDATE "))
      refute Enum.any?(data_queries, &String.starts_with?(&1, "DELETE "))
      refute Enum.any?(data_queries, &String.contains?(&1, "INVENTORY_ITEMS"))
    after
      :telemetry.detach(handler_id)
    end
  end

  test "guard_exact_generation fail-closed evidence matrix" do
    order = create_order!()
    other_order = create_order!()
    variant_id = UUIDv7.generate()
    other_variant = UUIDv7.generate()
    create_inventory_item!(variant_id, 8)
    create_inventory_item!(other_variant, 8)
    key = generation_key(order.id, variant_id)
    generic_key = "order:#{order.id}:sku:#{variant_id}"

    assert {:ok, {:error, :not_found}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, key, 1)
             end)

    assert {:ok, {:error, :invalid_identity}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, generic_key, 1)
             end)

    insert_direct_reservation!(other_order.id, variant_id, key, 1, :cancelled)

    assert {:ok, {:error, :contradictory_evidence}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, key, 1)
             end)

    Repo.delete_all(from r in InventoryReservation, where: r.reservation_key == ^key)

    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key, 2)

    assert {:ok, {:error, :invalid_identity}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, other_variant, key, 2)
             end)

    assert {:ok, {:error, :invalid_identity}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(other_order.id, variant_id, key, 2)
             end)

    assert {:ok, {:error, :quantity_mismatch}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, key, 1)
             end)

    assert {:ok, %{changed?: true}} =
             Store.Orders.release_exact_generation(order.id, variant_id, key)

    assert {:ok, {:error, :not_active}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, key, 2)
             end)

    consumed_key = generation_key(order.id, variant_id, UUIDv7.generate())

    assert {:ok, _} =
             Store.Orders.reserve_exact_generation(order.id, variant_id, consumed_key, 2)

    assert {:ok, %{changed?: true}} =
             Store.Orders.consume_exact_generation(order.id, variant_id, consumed_key)

    assert {:ok, {:error, :not_active}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, consumed_key, 2)
             end)

    expired_key = generation_key(order.id, variant_id, UUIDv7.generate())
    insert_direct_reservation!(order.id, variant_id, expired_key, 1, :expired)

    assert {:ok, {:error, :not_active}} =
             Repo.transaction(fn ->
               Store.Orders.guard_exact_generation(order.id, variant_id, expired_key, 1)
             end)
  end

  test "guard_exact_generation uses the unique reservation_key index shape" do
    {:ok, %{rows: [[index_definition]]}} =
      Repo.query("""
      SELECT indexdef
      FROM pg_indexes
      WHERE indexname = 'inventory_reservations_unique_reservation_key_index'
      """)

    order = create_order!()
    variant_id = UUIDv7.generate()
    create_inventory_item!(variant_id, 4)
    key = generation_key(order.id, variant_id)
    assert {:ok, _} = Store.Orders.reserve_exact_generation(order.id, variant_id, key, 1)

    {:ok, explain_result} =
      Repo.query(
        """
        EXPLAIN (FORMAT TEXT)
        SELECT *
        FROM inventory_reservations
        WHERE reservation_key = $1
        FOR UPDATE
        """,
        [key]
      )

    plan_lines = Enum.map_join(explain_result.rows, "\n", fn [line] -> line end)

    assert String.contains?(index_definition, "reservation_key")
    assert String.contains?(plan_lines, "reservation_key")
  end

  test "concurrent exact release blocks until guard transaction commits" do
    {order_id, variant_id} =
      with_committed_fixture(fn order, variant_id ->
        key = generation_key(order.id, variant_id)
        parent = self()

        assert {:ok, %{reservation: %{state: :active}}} =
                 Store.Orders.reserve_exact_generation(order.id, variant_id, key, 2)

        guard_task =
          Task.async(fn ->
            Sandbox.unboxed_run(Store.Repo, fn ->
              Repo.transaction(fn ->
                {:ok, %{rows: [[guard_backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])

                assert {:ok, %{state: :active}} =
                         Store.Orders.guard_exact_generation(order.id, variant_id, key, 2)

                send(parent, {:guard_acquired, guard_backend_pid})

                receive do
                  :commit_guard_transaction -> :ok
                after
                  10_000 -> Repo.rollback(:timed_out_waiting_for_guard_commit)
                end
              end)
            end)
          end)

        assert_receive {:guard_acquired, guard_backend_pid}, 10_000

        release_task =
          Task.async(fn ->
            Sandbox.unboxed_run(Store.Repo, fn ->
              receive do
                :start_release -> :ok
              after
                10_000 -> throw(:timed_out_waiting_to_start_release)
              end

              {:ok, %{rows: [[waiter_backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])
              send(parent, {:waiter_ready, waiter_backend_pid})

              Store.Orders.release_exact_generation(order.id, variant_id, key)
            end)
          end)

        send(release_task.pid, :start_release)
        assert_receive {:waiter_ready, waiter_backend_pid}, 10_000

        blocking_evidence =
          Sandbox.unboxed_run(Store.Repo, fn ->
            Process.sleep(50)

            {:ok, %{rows: [[blocking_pids]]}} =
              Repo.query("SELECT pg_blocking_pids($1::integer)", [waiter_backend_pid])

            blocking_pids || []
          end)

        assert guard_backend_pid in blocking_evidence

        send(guard_task.pid, :commit_guard_transaction)
        assert {:ok, :ok} = Task.await(guard_task, 10_000)

        assert {:ok, %{changed?: true, reservation: %{state: :cancelled}}} =
                 Task.await(release_task, 10_000)

        assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0

        {order.id, variant_id}
      end)

    Sandbox.unboxed_run(Store.Repo, fn ->
      refute Repo.exists?(from o in Order, where: o.id == ^order_id)
      refute Repo.exists?(from i in InventoryItem, where: i.variant_id == ^variant_id)

      assert Repo.aggregate(
               from(r in InventoryReservation, where: r.order_id == ^order_id),
               :count,
               :id
             ) == 0
    end)
  end

  test "concurrent exact release proceeds after guard transaction rolls back" do
    with_committed_fixture(fn order, variant_id ->
      key = generation_key(order.id, variant_id)
      parent = self()

      assert {:ok, %{reservation: %{state: :active}}} =
               Store.Orders.reserve_exact_generation(order.id, variant_id, key, 2)

      guard_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            Repo.transaction(fn ->
              {:ok, %{rows: [[guard_backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])

              assert {:ok, %{state: :active}} =
                       Store.Orders.guard_exact_generation(order.id, variant_id, key, 2)

              send(parent, {:guard_acquired, guard_backend_pid})

              receive do
                :rollback_guard_transaction -> Repo.rollback(:guard_rollback_probe)
              after
                10_000 -> Repo.rollback(:timed_out_waiting_for_guard_rollback)
              end
            end)
          end)
        end)

      assert_receive {:guard_acquired, guard_backend_pid}, 10_000

      release_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            receive do
              :start_release -> :ok
            after
              10_000 -> throw(:timed_out_waiting_to_start_release)
            end

            {:ok, %{rows: [[waiter_backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])
            send(parent, {:waiter_ready, waiter_backend_pid})

            Store.Orders.release_exact_generation(order.id, variant_id, key)
          end)
        end)

      send(release_task.pid, :start_release)
      assert_receive {:waiter_ready, waiter_backend_pid}, 10_000

      blocking_evidence =
        Sandbox.unboxed_run(Store.Repo, fn ->
          Process.sleep(50)

          {:ok, %{rows: [[blocking_pids]]}} =
            Repo.query("SELECT pg_blocking_pids($1::integer)", [waiter_backend_pid])

          blocking_pids || []
        end)

      assert guard_backend_pid in blocking_evidence

      send(guard_task.pid, :rollback_guard_transaction)
      assert {:error, :guard_rollback_probe} = Task.await(guard_task, 10_000)

      assert {:ok, %{changed?: true, reservation: %{state: :cancelled}}} =
               Task.await(release_task, 10_000)

      assert Repo.get_by!(InventoryItem, variant_id: variant_id).reserved_count == 0
    end)
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

  defp with_committed_fixture(fun, opts \\ []) do
    after_commit = Keyword.get(opts, :after_commit, fn _order, _variant_id -> :ok end)

    case create_committed_fixture!() do
      {:ok, {%Order{} = order, variant_id, notifications}} when is_binary(variant_id) ->
        try do
          AshNotifications.notify_post_commit(notifications,
            context: %{test_fixture: :inventory_reservation_generation}
          )

          verify_committed_fixture!(order, variant_id, :present)
          after_commit.(order, variant_id)

          Sandbox.unboxed_run(Store.Repo, fn -> fun.(order, variant_id) end)
        after
          cleanup_committed_fixture!(order, variant_id)
        end

      {:error, reason} ->
        raise "committed fixture setup transaction failed: #{inspect(reason)}"

      other ->
        raise "committed fixture setup returned an invalid result: #{inspect(other)}"
    end
  end

  defp create_committed_fixture!(after_order \\ fn _order, _variant_id -> :ok end) do
    Sandbox.unboxed_run(Store.Repo, fn -> create_committed_fixture_transaction(after_order) end)
  end

  defp create_committed_fixture_transaction(after_order) do
    Repo.transaction(fn ->
      {order, order_notifications} = create_committed_order!()
      variant_id = UUIDv7.generate()
      after_order.(order, variant_id)

      {_inventory_item, inventory_notifications} = create_committed_inventory_item!(variant_id, 4)

      {order, variant_id, order_notifications ++ inventory_notifications}
    end)
  end

  defp create_committed_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create(
      domain: Store.Orders,
      authorize?: false,
      return_notifications?: true
    )
    |> unwrap_fixture_create!()
  end

  defp create_committed_inventory_item!(variant_id, stock_on_hand) do
    InventoryItem
    |> Ash.Changeset.for_create(:create, %{
      variant_id: variant_id,
      stock_on_hand: stock_on_hand,
      reserved_count: 0
    })
    |> Ash.create(
      domain: Store.Catalog,
      authorize?: false,
      return_notifications?: true
    )
    |> unwrap_fixture_create!()
  end

  defp unwrap_fixture_create!({:ok, record, notifications}) when is_list(notifications),
    do: {record, notifications}

  defp unwrap_fixture_create!({:ok, record}), do: {record, []}

  defp unwrap_fixture_create!({:error, reason}),
    do: raise("committed fixture record creation failed: #{inspect(reason)}")

  defp cleanup_committed_fixture!(order, variant_id) do
    case Sandbox.unboxed_run(Store.Repo, fn ->
           cleanup_committed_fixture_transaction(order, variant_id)
         end) do
      {:ok, _deletes} ->
        verify_committed_fixture!(order, variant_id, :absent)

      {:error, reason} ->
        raise "committed fixture cleanup transaction failed: #{inspect(reason)}"
    end
  end

  defp cleanup_committed_fixture_transaction(order, variant_id) do
    Repo.transaction(fn ->
      reservation_deletes =
        Repo.delete_all(from r in InventoryReservation, where: r.order_id == ^order.id)

      inventory_deletes =
        Repo.delete_all(from i in InventoryItem, where: i.variant_id == ^variant_id)

      order_deletes = Repo.delete_all(from o in Order, where: o.id == ^order.id)

      {reservation_deletes, inventory_deletes, order_deletes}
    end)
  end

  defp verify_committed_fixture!(order, variant_id, expected) do
    {order_exists?, inventory_item_exists?, reservation_count} =
      Sandbox.unboxed_run(Store.Repo, fn ->
        order_exists? = Repo.exists?(from o in Order, where: o.id == ^order.id)

        inventory_item_exists? =
          Repo.exists?(from i in InventoryItem, where: i.variant_id == ^variant_id)

        reservation_count =
          Repo.aggregate(
            from(r in InventoryReservation, where: r.order_id == ^order.id),
            :count,
            :id
          )

        {order_exists?, inventory_item_exists?, reservation_count}
      end)

    valid? =
      case expected do
        :present -> order_exists? and inventory_item_exists?
        :absent -> not order_exists? and not inventory_item_exists? and reservation_count == 0
      end

    unless valid? do
      raise "committed fixture #{expected} verification failed for order #{order.id} and variant #{variant_id}"
    end
  end

  defp with_inventory_item_locked(variant_id, fun) do
    parent = self()

    lock_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Store.Repo, fn ->
          lock_inventory_item_in_transaction(variant_id, parent)
        end)
      end)

    assert_receive {:exact_inventory_item_locked, lock_backend_pid}, 10_000

    try do
      mutation_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            {:ok, %{rows: [[mutation_backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])

            {:ok, %{rows: [[default_lock_timeout]]}} =
              Repo.query("SELECT reset_val FROM pg_settings WHERE name = 'lock_timeout'", [])

            try do
              Repo.query!("SET lock_timeout = '100ms'")
              {mutation_backend_pid, fun.()}
            after
              Repo.query!("SET lock_timeout = DEFAULT")
              {:ok, %{rows: [[lock_timeout]]}} = Repo.query("SHOW lock_timeout", [])
              assert lock_timeout == default_lock_timeout
            end
          end)
        end)

      {mutation_backend_pid, result} = Task.await(mutation_task, 10_000)
      refute lock_backend_pid == mutation_backend_pid
      result
    after
      send(lock_task.pid, :release_exact_inventory_lock)
      Task.await(lock_task, 10_000)
    end
  end

  defp lock_inventory_item_in_transaction(variant_id, parent) do
    Repo.transaction(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("SELECT pg_backend_pid()", [])

      Repo.one!(
        from item in InventoryItem,
          where: item.variant_id == ^variant_id,
          lock: "FOR UPDATE"
      )

      send(parent, {:exact_inventory_item_locked, backend_pid})

      receive do
        :release_exact_inventory_lock -> :ok
      after
        10_000 -> Repo.rollback(:timed_out_waiting_to_release_inventory)
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
