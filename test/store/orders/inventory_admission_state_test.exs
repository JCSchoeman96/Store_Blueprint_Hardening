defmodule Store.Orders.InventoryAdmissionStateTest do
  use ExUnit.Case, async: true

  alias Store.Orders.InventoryAdmission
  alias Store.Orders.InventoryAdmission.{Lease, Operation, Request}

  @order_id "018ecb40-c457-73e6-a400-000398daddd7"
  @variant_id "018ecb40-c457-73e6-a400-000398daddd8"
  @other_variant_id "018ecb40-c457-73e6-a400-000398daddd9"
  @reservation_id "018ecb40-c457-73e6-a400-000398daddda"
  @expires_at ~U[2026-01-01 00:15:00Z]
  @states [
    :requested,
    :queued,
    :admitted,
    :reserving,
    :unknown_db_outcome,
    :recovering,
    :unresolved,
    :completed,
    :rejected,
    :expired,
    :abandoned
  ]
  @terminal_states [:completed, :rejected, :expired, :abandoned, :unresolved]
  @allowed_transitions [
    {:requested, :queued},
    {:requested, :admitted},
    {:queued, :admitted},
    {:queued, :expired},
    {:queued, :abandoned},
    {:admitted, :reserving},
    {:admitted, :expired},
    {:reserving, :completed},
    {:reserving, :rejected},
    {:reserving, :unknown_db_outcome},
    {:unknown_db_outcome, :recovering},
    {:recovering, :completed},
    {:recovering, :rejected},
    {:recovering, :unresolved}
  ]

  test "the admission state vocabulary is exact" do
    assert InventoryAdmission.states() == @states
    assert InventoryAdmission.terminal_states() == @terminal_states
  end

  test "terminal and live state semantics keep unresolved fail closed" do
    assert Enum.all?(@terminal_states, &InventoryAdmission.terminal?/1)
    assert InventoryAdmission.terminal?(:unresolved)
    refute InventoryAdmission.terminal?(:recovering)
    refute InventoryAdmission.terminal?(:unknown_db_outcome)

    assert Enum.all?(@states -- @terminal_states, &InventoryAdmission.live?/1)
    refute InventoryAdmission.live?(:unresolved)
    refute InventoryAdmission.live?(:completed)

    assert InventoryAdmission.blocks_new_operation?(:queued)
    assert InventoryAdmission.blocks_new_operation?(:admitted)
    assert InventoryAdmission.blocks_new_operation?(:reserving)
    assert InventoryAdmission.blocks_new_operation?(:unknown_db_outcome)
    assert InventoryAdmission.blocks_new_operation?(:recovering)
    assert InventoryAdmission.blocks_new_operation?(:unresolved)
    refute InventoryAdmission.blocks_new_operation?(:completed)
    refute InventoryAdmission.blocks_new_operation?(:bogus)
  end

  test "every frozen transition is valid and every other pair is rejected" do
    Enum.each(@allowed_transitions, fn {from, to} ->
      assert InventoryAdmission.valid_transition?(from, to)
      assert :ok = InventoryAdmission.validate_transition(from, to)
    end)

    Enum.each(@states, fn from ->
      Enum.each(@states, fn to ->
        if {from, to} not in @allowed_transitions do
          refute InventoryAdmission.valid_transition?(from, to)
          assert {:error, _reason} = InventoryAdmission.validate_transition(from, to)
        end
      end)
    end)

    Enum.each(@terminal_states, fn from ->
      Enum.each(@states, fn to ->
        refute InventoryAdmission.valid_transition?(from, to)
      end)
    end)

    refute InventoryAdmission.valid_transition?(:reserving, :expired)
    refute InventoryAdmission.valid_transition?(:unknown_db_outcome, :completed)
    refute InventoryAdmission.valid_transition?(:unknown_db_outcome, :rejected)
    refute Enum.any?(@states, &InventoryAdmission.valid_transition?(&1, :requested))
  end

  test "guard evidence is explicit for pure transition validation" do
    request = request()

    assert :ok =
             InventoryAdmission.validate_transition(:requested, :queued, request)

    assert :ok =
             InventoryAdmission.validate_transition(:requested, :admitted, request)

    assert :ok =
             InventoryAdmission.validate_transition(
               :queued,
               :admitted,
               :admission_granted
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :queued,
               :expired,
               :queue_deadline_elapsed
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :queued,
               :abandoned,
               :trusted_pre_reservation_abandonment
             )

    operation = operation(request)
    lease = lease_for(operation)

    assert :ok =
             InventoryAdmission.validate_transition(
               :admitted,
               :reserving,
               {:operation_and_lease, operation, lease}
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :admitted,
               :expired,
               :unclaimed_admitted_lease_expired
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :reserving,
               :completed,
               :known_commit
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :reserving,
               :rejected,
               :known_rollback
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :reserving,
               :unknown_db_outcome,
               :ambiguous_db_outcome
             )

    assert :ok =
             InventoryAdmission.validate_transition(
               :unknown_db_outcome,
               :recovering,
               :recovery_ownership_claimed
             )

    assert :ok =
             InventoryAdmission.validate_transition(:recovering, :completed, :post_match)

    assert :ok =
             InventoryAdmission.validate_transition(:recovering, :rejected, :pre_match)

    assert :ok =
             InventoryAdmission.validate_transition(:recovering, :unresolved, :neither_match)

    assert {:error, _reason} =
             InventoryAdmission.validate_transition(:reserving, :completed, :known_rollback)

    assert {:error, _reason} =
             InventoryAdmission.validate_transition(:admitted, :reserving, :not_a_lease)

    mismatched_lease = lease_for(operation, %{variant_id: @other_variant_id})

    assert {:error, :invalid_operation_or_lease_guard} =
             InventoryAdmission.validate_transition(
               :admitted,
               :reserving,
               {:operation_and_lease, operation, mismatched_lease}
             )
  end

  test "request derives one canonical durable identity from normalized UUIDs" do
    assert {:ok, lowercase} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: 1})

    assert {:ok, uppercase} =
             Request.new(%{
               order_id: String.upcase(@order_id),
               variant_id: String.upcase(@variant_id),
               quantity: 1
             })

    assert lowercase.order_id == @order_id
    assert lowercase.variant_id == @variant_id
    assert lowercase.reservation_key == "order:#{@order_id}:sku:#{@variant_id}"
    assert lowercase.reservation_key == uppercase.reservation_key
    assert lowercase.request_fingerprint == uppercase.request_fingerprint
  end

  test "request validates IDs and preserves zero quantity semantics" do
    assert {:error, _reason} =
             Request.new(%{order_id: "not-a-uuid", variant_id: @variant_id, quantity: 1})

    assert {:error, _reason} =
             Request.new(%{order_id: @order_id, variant_id: "not-a-uuid", quantity: 1})

    assert {:error, _reason} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: -1})

    assert {:ok, zero} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: 0})

    assert {:ok, positive} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: 2})

    assert zero.quantity == 0
    assert positive.quantity == 2
  end

  test "request owns reservation identity and excludes operation identity" do
    base = %{order_id: @order_id, variant_id: @variant_id, quantity: 1}

    assert {:error, :reservation_key_is_server_derived} =
             Request.new(Map.put(base, :reservation_key, "caller-selected"))

    assert {:error, :operation_id_is_server_generated} =
             Request.new(Map.put(base, :operation_id, "caller-selected"))

    assert {:error, :operation_epoch_is_server_generated} =
             Request.new(Map.put(base, :operation_epoch, 99))

    assert {:error, :unknown_request_key} =
             Request.new(Map.put(base, :client_clock, 100))

    assert {:error, :unknown_request_key} =
             Request.new(Map.put(base, :client_selected_deadline, 100))

    request = request()
    refute Map.has_key?(request, :operation_id)
    refute Map.has_key?(request, :operation_epoch)
    refute Map.has_key?(request, :client_clock)
    refute Map.has_key?(request, :lease_token)
  end

  test "request fingerprints track normalized mutation intent only" do
    base = %{order_id: @order_id, variant_id: @variant_id, quantity: 1}
    assert {:ok, first} = Request.new(base)
    assert {:ok, same} = Request.new(base)
    assert {:ok, changed_quantity} = Request.new(%{base | quantity: 2})

    assert first.request_fingerprint == same.request_fingerprint
    refute first.request_fingerprint == changed_quantity.request_fingerprint

    assert {:ok, changed_policy} =
             Request.new(Map.put(base, :expiry_policy, {:ttl_seconds, 60}))

    refute first.request_fingerprint == changed_policy.request_fingerprint

    assert {:ok, changed_kind} = Request.new(Map.put(base, :mutation_kind, :adjust))
    refute first.request_fingerprint == changed_kind.request_fingerprint

    first_operation = operation(first, now: ~U[2026-01-01 00:00:00Z])

    later_operation =
      operation(first,
        previous_epoch: first_operation.operation_epoch,
        now: ~U[2026-01-01 00:00:10Z]
      )

    assert first_operation.request_fingerprint == first.request_fingerprint
    assert later_operation.request_fingerprint == first.request_fingerprint
    assert first_operation.request_fingerprint == later_operation.request_fingerprint
    refute first_operation.operation_id == later_operation.operation_id
    refute first_operation.operation_epoch == later_operation.operation_epoch
  end

  test "operation generates server identity and validates epoch progression" do
    request = request()
    assert {:ok, first} = Operation.new(request, operation_inputs())

    assert {:ok, second} =
             Operation.new(
               request,
               Keyword.put(operation_inputs(), :previous_epoch, first.operation_epoch)
             )

    assert is_binary(first.operation_id)
    assert first.operation_id != first.reservation_key
    assert first.operation_id != second.operation_id
    assert first.operation_epoch == 1
    assert second.operation_epoch > first.operation_epoch
    assert Operation.valid_epoch?(first.operation_epoch)

    assert :ok =
             Operation.validate_epoch_progression(first.operation_epoch, second.operation_epoch)

    assert {:error, _reason} =
             Operation.validate_epoch_progression(second.operation_epoch, first.operation_epoch)

    assert {:error, :operation_id_is_server_generated} =
             Operation.new(
               request,
               Keyword.put(operation_inputs(), :operation_id, "caller-selected")
             )

    assert {:error, :operation_epoch_is_server_generated} =
             Operation.new(request, Keyword.put(operation_inputs(), :operation_epoch, 2))
  end

  test "operation requires explicit typed PRE, POST, and deadline evidence" do
    request = request()

    assert {:error, _reason} = Operation.new(request)

    assert {:ok, pre} = Operation.Pre.new(%{reservation: :absent, inventory: inventory_facts()})

    assert {:ok, existing_pre} =
             Operation.Pre.new(%{
               reservation: reservation_facts(%{}),
               inventory: inventory_facts()
             })

    assert {:ok, post} =
             Operation.Post.new(%{
               reservation: reservation_facts(%{id: nil}),
               inventory: inventory_facts(%{reserved_count: 1, version: 2})
             })

    assert {:ok, deadline} = Operation.Deadline.new(deadline_params())
    assert %Operation.Pre{} = pre
    assert existing_pre.reservation.id == @reservation_id
    assert %Operation.Post{} = post
    assert %Operation.Deadline{} = deadline

    assert {:error, _reason} =
             Operation.Pre.new(%{reservation: %{quantity: 1}, inventory: inventory_facts()})

    assert {:error, _reason} =
             Operation.Post.new(%{reservation: :absent, inventory: %{variant_id: @variant_id}})

    assert {:ok, operation} =
             Operation.new(request, pre: pre, post: post, deadline: deadline)

    assert operation.pre == pre
    assert operation.post == post
    assert operation.deadline == deadline
    assert operation.request_fingerprint == request.request_fingerprint
    assert :ok = Operation.validate(operation)
  end

  test "replay classification joins live exact replays and rejects mismatches" do
    request = request()
    changed_request = request(%{quantity: 2})
    operation = operation(request)

    for state <- [:requested, :queued, :admitted, :reserving, :unknown_db_outcome, :recovering] do
      assert InventoryAdmission.classify_replay(state, operation, request) ==
               :join_existing_operation

      assert InventoryAdmission.classify_replay(state, operation, changed_request) ==
               :mismatch_no_second_operation
    end
  end

  test "unresolved replay is fail closed regardless of fingerprint" do
    operation = operation(request())
    changed_request = request(%{quantity: 2})

    assert InventoryAdmission.classify_replay(:unresolved, operation, request()) == :fail_closed

    assert InventoryAdmission.classify_replay(:unresolved, operation, changed_request) ==
             :fail_closed
  end

  test "completed replay preserves durable outcome and changed mutation needs authorization" do
    operation = operation(request())
    changed_request = request(%{quantity: 2})

    assert InventoryAdmission.classify_replay(:completed, operation, request()) ==
             :return_existing_outcome

    assert InventoryAdmission.classify_replay(:completed, operation, changed_request) ==
             :requires_new_authorization
  end

  test "other terminal replay does not automatically create a new operation" do
    operation = operation(request())
    changed_request = request(%{quantity: 2})

    for state <- [:rejected, :expired, :abandoned] do
      assert InventoryAdmission.classify_replay(state, operation, request()) ==
               :return_existing_terminal

      assert InventoryAdmission.classify_replay(state, operation, changed_request) ==
               :requires_new_authorization
    end
  end

  test "a live reservation key can return only the existing operation identity" do
    request = request()
    first = operation(request)
    second = operation(request, previous_epoch: first.operation_epoch)

    assert first.reservation_key == second.reservation_key
    assert first.operation_id != second.operation_id

    assert InventoryAdmission.classify_replay(:reserving, first, request) ==
             :join_existing_operation

    assert InventoryAdmission.classify_replay(:reserving, first, request(%{quantity: 2})) ==
             :mismatch_no_second_operation
  end

  test "lease validates ownership identity and deadline safety" do
    operation = operation(request())
    assert {:ok, lease} = Lease.new(lease_params(operation))

    assert lease.variant_id == operation.mutation.variant_id
    assert lease.identity_digest == operation.request_fingerprint
    refute Map.has_key?(lease, :state)
    refute Map.has_key?(lease, :reservation_id)

    assert {:error, _reason} = Lease.new(Map.put(lease_params(operation), :admission_member, ""))
    assert {:error, _reason} = Lease.new(Map.put(lease_params(operation), :lease_token, ""))
    assert {:error, _reason} = Lease.new(Map.put(lease_params(operation), :identity_digest, ""))
    assert {:error, _reason} = Lease.new(Map.put(lease_params(operation), :owner_epoch, 0))

    assert {:error, _reason} =
             Lease.new(
               Map.merge(lease_params(operation), %{lease_deadline: 109, safety_margin: 10})
             )
  end

  test "deadline budgets use monotonic integers, decrease, and clamp at zero" do
    assert {:ok, deadline} = Operation.Deadline.new(deadline_params())
    assert Operation.Deadline.remaining_db_budget(deadline, 100) == 100
    assert Operation.Deadline.remaining_db_budget(deadline, 150) == 50
    assert Operation.Deadline.remaining_db_budget(deadline, 200) == 0
    assert Operation.Deadline.expired?(deadline, 200)
    refute Operation.Deadline.expired?(deadline, 199)

    operation = operation(request())
    lease = lease_for(operation)
    assert Lease.remaining_db_budget(lease, 100) == 100
    assert Lease.remaining_db_budget(lease, 250) == 0

    assert {:error, _reason} =
             Operation.Deadline.new(%{
               db_deadline: 100,
               lease_deadline: 120,
               recovery_deadline: 119,
               safety_margin: 10
             })
  end

  test "K_v is an immutable single-variant constant" do
    assert InventoryAdmission.k_v() == 1
    assert InventoryAdmission.variant_permit_count() == 1
  end

  defp request(attrs \\ %{}) do
    params = Map.merge(%{order_id: @order_id, variant_id: @variant_id, quantity: 1}, attrs)
    assert {:ok, request} = Request.new(params)
    request
  end

  defp operation_inputs do
    [
      pre: pre_facts(),
      post: post_facts(),
      deadline: deadline_params()
    ]
  end

  defp operation(request, attrs \\ []) do
    assert {:ok, operation} = Operation.new(request, Keyword.merge(operation_inputs(), attrs))
    operation
  end

  defp deadline_params(attrs \\ %{}) do
    Map.merge(
      %{
        db_deadline: 200,
        lease_deadline: 220,
        recovery_deadline: 260,
        safety_margin: 10
      },
      attrs
    )
  end

  defp inventory_facts(attrs \\ %{}) do
    assert {:ok, facts} =
             Operation.InventoryFacts.new(
               Map.merge(
                 %{
                   variant_id: @variant_id,
                   stock_on_hand: 10,
                   reserved_count: 0,
                   allow_oversell: false,
                   version: 1
                 },
                 attrs
               )
             )

    facts
  end

  defp reservation_facts(attrs) do
    assert {:ok, facts} =
             Operation.ReservationFacts.new(
               Map.merge(
                 %{
                   id: @reservation_id,
                   quantity: 1,
                   state: :active,
                   expires_at: @expires_at,
                   version: 1
                 },
                 attrs
               )
             )

    facts
  end

  defp pre_facts(attrs \\ %{}) do
    assert {:ok, facts} =
             Operation.Pre.new(%{reservation: :absent, inventory: inventory_facts(attrs)})

    facts
  end

  defp post_facts(attrs \\ %{}) do
    assert {:ok, facts} =
             Operation.Post.new(%{
               reservation: reservation_facts(%{id: nil}),
               inventory: inventory_facts(Map.merge(%{reserved_count: 1, version: 2}, attrs))
             })

    facts
  end

  defp lease_params(operation, attrs \\ %{}) do
    Map.merge(
      %{
        admission_member: "member-1",
        variant_id: operation.mutation.variant_id,
        lease_token: "lease-token-1",
        owner_epoch: 1,
        identity_digest: operation.request_fingerprint,
        db_deadline: operation.deadline.db_deadline,
        lease_deadline: operation.deadline.lease_deadline,
        safety_margin: operation.deadline.safety_margin
      },
      attrs
    )
  end

  defp lease_for(operation, attrs \\ %{}) do
    assert {:ok, lease} = Lease.new(lease_params(operation, attrs))
    lease
  end
end
