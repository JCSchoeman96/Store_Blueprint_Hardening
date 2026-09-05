defmodule Store.Orders.InventoryAdmissionRedisTest do
  use ExUnit.Case, async: false

  alias Store.Orders.InventoryAdmission.Redis
  alias Store.Orders.InventoryAdmission.Request
  alias Store.Support.ID.UUIDv7
  alias Store.Support.RateLimit.RedixClient

  @hmac_key "ia02-test-only-trusted-key-material"
  @order_id "018ecb40-c457-73e6-a400-000398daddd7"
  @second_order_id "018ecb40-c457-73e6-a400-000398daddd8"
  @variant_id "018ecb40-c457-73e6-a400-000398daddd9"
  @second_variant_id "018ecb40-c457-73e6-a400-000398dadda0"
  @third_variant_id "018ecb40-c457-73e6-a400-000398dadda1"
  @operation_id "018ecb40-c457-73e6-a400-000398daddaa"
  @max_test_cleanup_records 128

  setup do
    scope = "ia02_test_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    Process.put(:ia02_scope, scope)
    {:ok, scope: scope}
  end

  test "versioned keys share one explicit hash tag and hide commercial identity", %{scope: scope} do
    request = request()
    other_request = request(@second_order_id, @second_variant_id)
    member = Redis.admission_member(request.identity_digest, @hmac_key)
    other_member = Redis.admission_member(other_request.identity_digest, @hmac_key)

    assert is_binary(member)
    assert member != request.reservation_key
    assert member != other_member

    assert {:ok, keys} =
             Redis.key_set(request.variant_id, member, request.identity_digest, scope: scope)

    assert {:ok, other_keys} =
             Redis.key_set(
               other_request.variant_id,
               other_member,
               other_request.identity_digest,
               scope: scope
             )

    assert keys.hash_tag == other_keys.hash_tag
    assert keys.variant_hex == String.replace(request.variant_id, "-", "")
    assert other_keys.variant_hex == String.replace(other_request.variant_id, "-", "")

    atomic_keys =
      keys
      |> Map.take([
        :global_sequence,
        :variant_queue_order,
        :global_queue_dispatch,
        :global_queue_expiry,
        :variant_active,
        :global_active_expiry,
        :request_meta,
        :reservation_fence
      ])
      |> Map.values()

    assert Enum.all?(atomic_keys, &String.contains?(&1, keys.hash_tag))
    assert Enum.all?(atomic_keys, &(not String.contains?(&1, request.reservation_key)))
    assert Enum.all?(atomic_keys, &(not String.contains?(&1, other_request.reservation_key)))
    assert String.contains?(keys.variant_queue_order, keys.variant_hex)
    assert String.contains?(other_keys.variant_queue_order, other_keys.variant_hex)
    refute keys.variant_queue_order == other_keys.variant_queue_order

    assert {:ok, v2_keys} =
             Redis.key_set(
               request.variant_id,
               member,
               request.identity_digest,
               scope: scope,
               version: "v2"
             )

    refute keys.namespace == v2_keys.namespace
    refute keys.hash_tag == v2_keys.hash_tag
    assert String.contains?(v2_keys.variant_queue_order, v2_keys.variant_hex)
  end

  test "on_exit cleanup removes every exact scoped key", %{scope: scope} do
    request = request()
    keys = keys_for(request, scope)
    member = Redis.admission_member(request.identity_digest, @hmac_key)

    owned_keys = [
      keys.global_sequence,
      keys.variant_queue_order,
      keys.variant_active,
      keys.global_queue_dispatch,
      keys.global_queue_expiry,
      keys.global_active_expiry,
      keys.request_meta,
      keys.reservation_fence
    ]

    assert {:ok, "OK"} = redis(["SET", keys.global_sequence, "1"])
    assert {:ok, 1} = redis(["ZADD", keys.variant_queue_order, "1", member])
    assert {:ok, 1} = redis(["HSET", keys.variant_active, "state", "ADMITTED"])
    assert {:ok, 1} = redis(["ZADD", keys.global_queue_dispatch, "1", member])
    assert {:ok, 1} = redis(["ZADD", keys.global_queue_expiry, "1", member])
    assert {:ok, 1} = redis(["ZADD", keys.global_active_expiry, "1", member])
    assert {:ok, 1} = redis(["HSET", keys.request_meta, "state", "REQUESTED"])
    assert {:ok, 1} = redis(["HSET", keys.reservation_fence, "state", "REQUESTED"])
    assert {:ok, existing_key_count} = redis(["EXISTS" | owned_keys])
    assert existing_key_count == length(owned_keys)
  end

  test "opaque member derivation is stable per identity and key version" do
    request = request()
    same_identity = request(@order_id, @variant_id, 2)
    other_identity = request(@second_order_id, @variant_id)

    assert request.identity_digest == same_identity.identity_digest

    assert Redis.admission_member(request.identity_digest, @hmac_key) ==
             Redis.admission_member(same_identity.identity_digest, @hmac_key)

    refute Redis.admission_member(request.identity_digest, @hmac_key) ==
             Redis.admission_member(other_identity.identity_digest, @hmac_key)

    assert {:ok, version_one} =
             Redis.derive_admission_member(request.identity_digest, @hmac_key, "v1")

    assert {:ok, version_two} =
             Redis.derive_admission_member(request.identity_digest, @hmac_key, "v2")

    refute version_one == version_two
    assert {:error, :invalid_input} = Redis.derive_admission_member(request.identity_digest, nil)
  end

  test "decoder is closed and never creates atoms from Redis replies" do
    request = request()
    member = Redis.admission_member(request.identity_digest, @hmac_key)
    {:ok, variant_hex} = Redis.normalize_variant_key(request.variant_id)

    valid_fields = [
      "QUEUED",
      member,
      variant_hex,
      request.identity_digest,
      request.request_fingerprint,
      @operation_id,
      "1",
      "1",
      "1000",
      "",
      "",
      "",
      "",
      ""
    ]

    assert {:ok, {:queued, decoded}} =
             Redis.decode_result(["IA02_QUEUED" | valid_fields])

    assert decoded.state == :queued
    assert decoded.variant_id == request.variant_id
    assert decoded.identity_digest == request.identity_digest

    assert {:error, :unavailable} = Redis.decode_result(["IA02_UNKNOWN"])
    assert {:error, :unavailable} = Redis.decode_result(["IA02_QUEUED"])
    assert {:error, :unavailable} = Redis.decode_result(["IA02_QUEUED" | List.duplicate("", 14)])

    malformed_type = List.replace_at(valid_fields, 6, 1)
    assert {:error, :unavailable} = Redis.decode_result(["IA02_QUEUED" | malformed_type])

    malformed_state = List.replace_at(valid_fields, 0, "NOT_A_STATE")
    assert {:error, :unavailable} = Redis.decode_result(["IA02_QUEUED" | malformed_state])
    assert {:error, :unavailable} = Redis.decode_result(["IA02_UNAVAILABLE", "extra"])
  end

  test "missing trusted HMAC material fails closed before Redis admission", %{scope: scope} do
    assert {:error, :unavailable} =
             Redis.enqueue_or_return_existing(
               request(),
               opts(scope) |> Keyword.delete(:hmac_key)
             )
  end

  test "empty capacity admits immediately and exact replay returns the same lease", %{
    scope: scope
  } do
    request = request()
    options = opts(scope, b_total: 2)

    assert {:ok, {:admitted, first}} =
             Redis.enqueue_or_return_existing(request, options)

    assert first.state == :admitted
    assert first.status == :admitted
    assert first.variant_id == request.variant_id
    assert first.identity_digest == request.identity_digest
    assert first.identity_digest != first.request_fingerprint
    assert first.operation_id != request.reservation_key
    assert first.operation_epoch == 1
    assert is_binary(first.lease_token)

    assert {:ok, {:existing, replay}} =
             Redis.enqueue_or_return_existing(request, options)

    assert replay.operation_id == first.operation_id
    assert replay.operation_epoch == first.operation_epoch
    assert replay.member == first.member
    assert replay.lease_token == first.lease_token

    keys = keys_for(request, scope)
    assert {:ok, 1} = redis(["ZCARD", keys.global_active_expiry])
    assert {:ok, 0} = redis(["ZCARD", keys.variant_queue_order])
    assert {:ok, 0} = redis(["ZCARD", keys.global_queue_dispatch])
    assert {:ok, 0} = redis(["ZCARD", keys.global_queue_expiry])

    metadata = hgetall(keys.request_meta)
    assert metadata["schema_version"] == Redis.record_version()
    assert metadata["state"] == "ADMITTED"
    assert metadata["identity_digest"] == request.identity_digest
    assert metadata["request_fingerprint"] == request.request_fingerprint
    assert metadata["variant_hex"] == keys.variant_hex
    refute Map.has_key?(metadata, "stock_on_hand")
    refute Map.has_key?(metadata, "reserved_count")
    refute Map.has_key?(metadata, "available")
  end

  test "changed live fingerprint mismatches without allocating another operation", %{scope: scope} do
    original = request()
    changed = request(@order_id, @variant_id, 2)
    options = opts(scope, b_total: 2)

    assert {:ok, {:admitted, admitted}} =
             Redis.enqueue_or_return_existing(original, options)

    assert {:ok, :mismatch} =
             Redis.enqueue_or_return_existing(changed, options)

    assert {:ok, {:existing, replay}} =
             Redis.enqueue_or_return_existing(original, options)

    assert replay.operation_id == admitted.operation_id
    assert replay.operation_epoch == admitted.operation_epoch
    assert redis(["ZCARD", keys_for(original, scope).global_active_expiry]) == {:ok, 1}
  end

  test "same-variant occupancy queues while another variant can use remaining global capacity", %{
    scope: scope
  } do
    first = request()
    same_variant = request(@second_order_id, @variant_id)
    other_variant = request(@second_order_id, @second_variant_id)
    options = opts(scope, b_total: 2)

    assert {:ok, {:admitted, _first_admission}} =
             Redis.enqueue_or_return_existing(first, options)

    assert {:ok, {:queued, queued}} =
             Redis.enqueue_or_return_existing(same_variant, options)

    assert_queue_indexes(keys_for(same_variant, scope), queued.member)

    assert {:ok, {:admitted, other_admission}} =
             Redis.enqueue_or_return_existing(other_variant, options)

    assert other_admission.state == :admitted
    assert redis(["ZCARD", keys_for(first, scope).global_active_expiry]) == {:ok, 2}

    assert redis(["HGET", keys_for(same_variant, scope).variant_active, "state"]) ==
             {:ok, "ADMITTED"}

    assert redis(["HGET", keys_for(same_variant, scope).variant_active, "member"]) !=
             {:ok, queued.member}

    assert {:ok, {:existing, replay}} =
             Redis.enqueue_or_return_existing(same_variant, options)

    assert replay.operation_id == queued.operation_id
    assert redis(["ZCARD", keys_for(same_variant, scope).variant_queue_order]) == {:ok, 1}
  end

  test "variant and global queue bounds reject only new identities and keep replay idempotent", %{
    scope: scope
  } do
    first = request()
    variant_waiter = request(@second_order_id, @variant_id)
    variant_overflow = request(@third_variant_id, @variant_id)
    global_waiter = request(@second_order_id, @second_variant_id)
    global_overflow = request(@third_variant_id, @second_variant_id)
    options = opts(scope, b_total: 1, q_variant_max: 1, q_global_max: 2)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)
    assert {:ok, {:queued, _}} = Redis.enqueue_or_return_existing(variant_waiter, options)
    assert {:ok, :busy} = Redis.enqueue_or_return_existing(variant_overflow, options)

    assert {:ok, {:existing, _}} =
             Redis.enqueue_or_return_existing(variant_waiter, options)

    assert {:ok, {:queued, _}} = Redis.enqueue_or_return_existing(global_waiter, options)
    assert {:ok, :busy} = Redis.enqueue_or_return_existing(global_overflow, options)

    assert redis(["ZCARD", keys_for(variant_waiter, scope).variant_queue_order]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(global_waiter, scope).global_queue_dispatch]) == {:ok, 2}
    assert redis(["ZCARD", keys_for(global_waiter, scope).global_queue_expiry]) == {:ok, 2}
  end

  test "queue order uses a Redis sequence while expiry uses a separate Redis deadline", %{
    scope: scope
  } do
    first = request()

    waiters =
      Enum.map(1..3, fn _index ->
        request(UUIDv7.generate(), @variant_id)
      end)

    options = opts(scope, b_total: 1, q_variant_max: 5, q_global_max: 5, queue_window_ms: 5_000)
    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)

    queued_admissions =
      Enum.map(waiters, fn waiter ->
        assert {:ok, {:queued, queued}} =
                 Redis.enqueue_or_return_existing(waiter, options)

        queued
      end)

    assert Enum.all?(queued_admissions, &(&1.operation_epoch == &1.sequence))

    keys = keys_for(hd(waiters), scope)
    assert {:ok, ordered} = redis(["ZRANGE", keys.variant_queue_order, "0", "-1", "WITHSCORES"])

    assert {:ok, expiry_order} =
             redis(["ZRANGE", keys.global_queue_expiry, "0", "-1", "WITHSCORES"])

    ordered_scores = scores_for(ordered)
    expiry_scores = scores_for(expiry_order)
    assert ordered_scores == Enum.sort(ordered_scores)
    assert Enum.all?(expiry_scores, &is_integer/1)
    assert Enum.all?(ordered_scores, &is_integer/1)
    refute ordered_scores == expiry_scores

    {:ok, [seconds, microseconds]} = redis(["TIME"])

    server_now_ms =
      String.to_integer(seconds) * 1_000 + div(String.to_integer(microseconds), 1_000)

    assert Enum.all?(expiry_scores, &(&1 > server_now_ms))

    ordered_members =
      ordered
      |> Enum.chunk_every(2)
      |> Enum.map(fn [member, _score] -> member end)

    assert Enum.uniq(ordered_members) == ordered_members
  end

  test "promotion requires both capacities and cannot leapfrog the variant head", %{scope: scope} do
    first = request()
    head_request = request(@second_order_id, @variant_id)
    tail_request = request(@third_variant_id, @variant_id)
    options = opts(scope, b_total: 2, q_variant_max: 5, q_global_max: 5)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)
    assert {:ok, {:queued, head}} = Redis.enqueue_or_return_existing(head_request, options)
    assert {:ok, {:queued, _tail}} = Redis.enqueue_or_return_existing(tail_request, options)

    assert {:ok, :busy} = Redis.promote_queued(tail_request, promotion_opts(scope, 2))
    assert {:ok, 2} = redis(["ZCARD", keys_for(head_request, scope).variant_queue_order])
    assert redis(["ZCARD", keys_for(head_request, scope).global_active_expiry]) == {:ok, 1}

    delete_active(first, scope)

    assert {:ok, {:admitted, promoted}} =
             Redis.promote_queued(head_request, promotion_opts(scope, 2))

    assert promoted.operation_id == head.operation_id
    assert promoted.operation_epoch == head.operation_epoch
    assert redis(["ZCARD", keys_for(head_request, scope).variant_queue_order]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(head_request, scope).global_queue_dispatch]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(head_request, scope).global_queue_expiry]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(head_request, scope).global_active_expiry]) == {:ok, 1}

    global_full_request = request(@order_id, @second_variant_id)

    assert {:ok, {:admitted, _}} =
             Redis.enqueue_or_return_existing(global_full_request, opts(scope, b_total: 2))

    global_waiter = request(UUIDv7.generate(), @third_variant_id)

    assert {:ok, {:queued, _}} =
             Redis.enqueue_or_return_existing(global_waiter, opts(scope, b_total: 2))

    assert {:ok, :busy} =
             Redis.promote_queued(global_waiter, promotion_opts(scope, 2))

    assert redis(["ZCARD", keys_for(head_request, scope).global_active_expiry]) == {:ok, 2}
    assert redis(["HGET", keys_for(global_waiter, scope).variant_active, "state"]) == {:ok, nil}
    assert redis(["ZCARD", keys_for(global_waiter, scope).global_queue_dispatch]) == {:ok, 2}
    assert redis(["ZCARD", keys_for(global_waiter, scope).global_queue_expiry]) == {:ok, 2}
  end

  test "expired queued heads become terminal and unblock the valid tail", %{scope: scope} do
    first = request()
    head_request = request(@second_order_id, @variant_id)
    tail_request = request(@third_variant_id, @variant_id)
    options = opts(scope, b_total: 2, q_variant_max: 5, q_global_max: 5)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)

    assert {:ok, {:queued, queued_head}} =
             Redis.enqueue_or_return_existing(head_request, options)

    assert {:ok, {:queued, _}} = Redis.enqueue_or_return_existing(tail_request, options)

    shorten_evidence_ttl(head_request, scope, 50)
    force_expired_queued(head_request, scope)

    assert {:ok, {:existing, expired}} =
             Redis.promote_queued(head_request, promotion_opts(scope, 2))

    assert expired.state == :expired
    assert expired.member == queued_head.member
    assert expired.operation_id == queued_head.operation_id
    assert expired.operation_epoch == queued_head.operation_epoch

    assert {:ok, refreshed_meta_ttl} =
             redis(["PTTL", keys_for(head_request, scope).request_meta])

    assert {:ok, refreshed_fence_ttl} =
             redis(["PTTL", keys_for(head_request, scope).reservation_fence])

    assert refreshed_meta_ttl > 1_000
    assert refreshed_fence_ttl > 1_000

    assert redis(["HGET", keys_for(head_request, scope).request_meta, "state"]) ==
             {:ok, "EXPIRED"}

    assert redis(["HGET", keys_for(head_request, scope).reservation_fence, "state"]) ==
             {:ok, "EXPIRED"}

    assert redis(["ZSCORE", keys_for(head_request, scope).variant_queue_order, expired.member]) ==
             {:ok, nil}

    assert redis(["ZSCORE", keys_for(head_request, scope).global_queue_dispatch, expired.member]) ==
             {:ok, nil}

    assert redis(["ZSCORE", keys_for(head_request, scope).global_queue_expiry, expired.member]) ==
             {:ok, nil}

    assert redis(["ZCARD", keys_for(head_request, scope).global_active_expiry]) == {:ok, 1}

    delete_active(first, scope)

    assert {:ok, {:admitted, promoted}} =
             Redis.promote_queued(tail_request, promotion_opts(scope, 2))

    assert promoted.state == :admitted
    assert redis(["ZCARD", keys_for(tail_request, scope).variant_queue_order]) == {:ok, 0}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_queue_dispatch]) == {:ok, 0}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_queue_expiry]) == {:ok, 0}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_active_expiry]) == {:ok, 1}
  end

  test "expired queued entries free both queue bounds and replay as terminal", %{scope: scope} do
    first = request()
    expired_request = request(@second_order_id, @variant_id)
    tail_request = request(@third_variant_id, @variant_id)
    options = opts(scope, b_total: 1, q_variant_max: 1, q_global_max: 1)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)

    assert {:ok, {:queued, queued_expired}} =
             Redis.enqueue_or_return_existing(expired_request, options)

    force_expired_queued(expired_request, scope)

    assert {:ok, {:existing, expired}} =
             Redis.enqueue_or_return_existing(expired_request, options)

    assert expired.state == :expired
    assert expired.member == queued_expired.member
    assert expired.operation_id == queued_expired.operation_id
    assert expired.operation_epoch == queued_expired.operation_epoch

    assert {:ok, :frozen} =
             Redis.enqueue_or_return_existing(request(@second_order_id, @variant_id, 2), options)

    assert {:ok, {:queued, queued_tail}} =
             Redis.enqueue_or_return_existing(tail_request, options)

    assert queued_tail.state == :queued
    assert redis(["ZCARD", keys_for(tail_request, scope).variant_queue_order]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_queue_dispatch]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_queue_expiry]) == {:ok, 1}
    assert redis(["ZCARD", keys_for(tail_request, scope).global_active_expiry]) == {:ok, 1}
  end

  test "queued evidence outlives its deadline and refreshes terminal retention", %{scope: scope} do
    first = request()
    queued_request = request(@second_order_id, @variant_id)

    options =
      opts(
        scope,
        b_total: 1,
        queue_window_ms: 250,
        metadata_retention_ms: 5_000
      )

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)

    assert {:ok, {:queued, _queued}} =
             Redis.enqueue_or_return_existing(queued_request, options)

    keys = keys_for(queued_request, scope)
    assert {:ok, queue_deadline_ms} = redis(["HGET", keys.request_meta, "queue_deadline_ms"])
    {:ok, [seconds, microseconds]} = redis(["TIME"])

    now_ms =
      String.to_integer(seconds) * 1_000 +
        div(String.to_integer(microseconds), 1_000)

    queue_deadline_ms = String.to_integer(queue_deadline_ms)
    assert queue_deadline_ms > now_ms
    assert queue_deadline_ms - now_ms <= options[:queue_window_ms]

    assert {:ok, initial_meta_ttl} = redis(["PTTL", keys.request_meta])
    assert {:ok, initial_fence_ttl} = redis(["PTTL", keys.reservation_fence])
    assert initial_meta_ttl > options[:queue_window_ms]
    assert initial_fence_ttl > options[:queue_window_ms]

    shorten_evidence_ttl(queued_request, scope, 50)
    force_expired_queued(queued_request, scope)

    assert {:ok, {:existing, expired}} =
             Redis.enqueue_or_return_existing(queued_request, options)

    assert expired.state == :expired
    assert {:ok, refreshed_meta_ttl} = redis(["PTTL", keys.request_meta])
    assert {:ok, refreshed_fence_ttl} = redis(["PTTL", keys.reservation_fence])
    assert refreshed_meta_ttl > 0
    assert refreshed_fence_ttl > 0
    assert refreshed_meta_ttl > 1_000
    assert refreshed_fence_ttl > 1_000
    assert refreshed_meta_ttl <= options[:metadata_retention_ms]
    assert refreshed_fence_ttl <= options[:metadata_retention_ms]
    assert refreshed_meta_ttl > 50
    assert refreshed_fence_ttl > 50
    assert redis(["HGET", keys.request_meta, "state"]) == {:ok, "EXPIRED"}
    assert redis(["HGET", keys.reservation_fence, "state"]) == {:ok, "EXPIRED"}

    assert {:ok, {:existing, replayed}} =
             Redis.enqueue_or_return_existing(queued_request, options)

    assert replayed.operation_id == expired.operation_id
    assert replayed.operation_epoch == expired.operation_epoch
    assert redis(["ZCARD", keys.variant_queue_order]) == {:ok, 0}
    assert redis(["ZCARD", keys.global_queue_dispatch]) == {:ok, 0}
    assert redis(["ZCARD", keys.global_queue_expiry]) == {:ok, 0}
    assert redis(["ZCARD", keys.global_active_expiry]) == {:ok, 1}
  end

  test "admitted evidence outlives its lease and DB safety window", %{scope: scope} do
    admitted_request = request()

    options =
      opts(
        scope,
        b_total: 1,
        queue_window_ms: 100,
        db_window_ms: 2_000,
        lease_window_ms: 3_000,
        safety_margin_ms: 500,
        metadata_retention_ms: 100
      )

    assert {:ok, {:admitted, _}} =
             Redis.enqueue_or_return_existing(admitted_request, options)

    keys = keys_for(admitted_request, scope)
    assert {:ok, meta_ttl} = redis(["PTTL", keys.request_meta])
    assert {:ok, fence_ttl} = redis(["PTTL", keys.reservation_fence])
    assert meta_ttl > options[:lease_window_ms] + options[:safety_margin_ms]
    assert fence_ttl > options[:lease_window_ms] + options[:safety_margin_ms]
  end

  test "expired queue entries with missing evidence fail closed", %{scope: scope} do
    first = request()
    orphaned = request(@second_order_id, @variant_id)
    options = opts(scope, b_total: 1, q_variant_max: 1, q_global_max: 1)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)
    assert {:ok, {:queued, _}} = Redis.enqueue_or_return_existing(orphaned, options)
    keys = keys_for(orphaned, scope)
    force_expired_queued(orphaned, scope)
    assert {:ok, 2} = redis(["DEL", keys.request_meta, keys.reservation_fence])

    assert {:error, :unavailable} =
             Redis.enqueue_or_return_existing(
               request(UUIDv7.generate(), @second_variant_id),
               options
             )

    assert redis(["ZCARD", keys.variant_queue_order]) == {:ok, 1}
    assert redis(["ZCARD", keys.global_queue_dispatch]) == {:ok, 1}
    assert redis(["ZCARD", keys.global_queue_expiry]) == {:ok, 1}
    assert redis(["ZCARD", keys.global_active_expiry]) == {:ok, 1}
  end

  test "expired cleanup is bounded per admission attempt", %{scope: scope} do
    first = request()
    expired_requests = Enum.map(1..3, &request(UUIDv7.generate(), @variant_id, &1))
    replacement = request(UUIDv7.generate(), @variant_id)
    options = opts(scope, b_total: 1, q_variant_max: 3, q_global_max: 3)

    assert {:ok, {:admitted, _}} = Redis.enqueue_or_return_existing(first, options)

    for expired_request <- expired_requests do
      assert {:ok, {:queued, _}} =
               Redis.enqueue_or_return_existing(expired_request, options)
    end

    for expired_request <- expired_requests do
      force_expired_queued(expired_request, scope)
    end

    assert {:ok, {:queued, _}} =
             Redis.enqueue_or_return_existing(
               replacement,
               Keyword.put(options, :cleanup_limit, 1)
             )

    states =
      Enum.map(expired_requests, fn expired_request ->
        keys = keys_for(expired_request, scope)
        redis(["HGET", keys.request_meta, "state"])
      end)

    assert Enum.count(states, &(&1 == {:ok, "EXPIRED"})) == 1
    assert Enum.count(states, &(&1 == {:ok, "QUEUED"})) == 2
  end

  test "operation epochs use the persistent namespace sequence", %{scope: scope} do
    first = request()
    changed = request(@order_id, @variant_id, 2)
    options = opts(scope, b_total: 2)

    assert {:ok, {:admitted, admitted}} =
             Redis.enqueue_or_return_existing(first, options)

    keys = keys_for(first, scope)
    assert {:ok, sequence_before} = redis(["GET", keys.global_sequence])
    assert is_binary(sequence_before)
    sequence_before = String.to_integer(sequence_before)
    assert admitted.operation_epoch > 0
    assert admitted.operation_epoch == sequence_before

    assert {:ok, {:existing, replay}} =
             Redis.enqueue_or_return_existing(first, options)

    assert replay.operation_epoch == admitted.operation_epoch

    assert {:ok, :mismatch} =
             Redis.enqueue_or_return_existing(changed, options)

    assert {:ok, sequence_after_replay} = redis(["GET", keys.global_sequence])
    assert String.to_integer(sequence_after_replay) == sequence_before

    busy_options = opts(scope, b_total: 2, q_variant_max: 0, q_global_max: 0)

    assert {:ok, :busy} =
             Redis.enqueue_or_return_existing(
               request(@second_order_id, @variant_id),
               busy_options
             )

    assert {:ok, sequence_after_busy} = redis(["GET", keys.global_sequence])
    assert String.to_integer(sequence_after_busy) == sequence_before

    delete_active(first, scope)
    assert {:ok, 2} = redis(["DEL", keys.request_meta, keys.reservation_fence])

    assert {:ok, {:admitted, later}} =
             Redis.enqueue_or_return_existing(changed, options)

    assert later.operation_epoch > admitted.operation_epoch
    assert {:ok, later_sequence} = redis(["GET", keys.global_sequence])
    assert String.to_integer(later_sequence) == later.operation_epoch
  end

  test "concurrent same-variant contenders have one active holder and bounded queue", %{
    scope: scope
  } do
    requests =
      Enum.map(1..20, fn _index ->
        request(UUIDv7.generate(), @variant_id)
      end)

    options = opts(scope, b_total: 3, q_variant_max: 100, q_global_max: 100)

    results =
      requests
      |> Task.async_stream(
        fn admission_request ->
          Redis.enqueue_or_return_existing(admission_request, options)
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {:admitted, _}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:queued, _}}, &1)) == 19

    keys = keys_for(hd(requests), scope)
    assert redis(["ZCARD", keys.variant_queue_order]) == {:ok, 19}
    assert redis(["ZCARD", keys.global_active_expiry]) == {:ok, 1}
  end

  test "concurrent distinct variants never exceed the global budget", %{scope: scope} do
    requests =
      Enum.map(1..20, fn _index ->
        request(UUIDv7.generate(), UUIDv7.generate())
      end)

    options = opts(scope, b_total: 3, q_variant_max: 100, q_global_max: 100)

    results =
      requests
      |> Task.async_stream(
        fn admission_request ->
          Redis.enqueue_or_return_existing(admission_request, options)
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    admitted = Enum.count(results, &match?({:ok, {:admitted, _}}, &1))
    assert admitted == 3
    assert Enum.count(results, &match?({:ok, {:queued, _}}, &1)) == 17
    assert redis(["ZCARD", keys_for(hd(requests), scope).global_active_expiry]) == {:ok, 3}
  end

  test "UNRESOLVED metadata is frozen for exact and changed fingerprints", %{scope: scope} do
    request = request()
    seed_unresolved(request, scope)

    assert {:ok, :frozen} =
             Redis.enqueue_or_return_existing(request, opts(scope, b_total: 2))

    changed = request(@order_id, @variant_id, 2)

    assert {:ok, :frozen} =
             Redis.enqueue_or_return_existing(changed, opts(scope, b_total: 2))
  end

  test "wrong Redis types and namespace versions fail closed", %{scope: scope} do
    request = request()
    keys = keys_for(request, scope)

    assert {:ok, "OK"} = redis(["SET", keys.variant_queue_order, "wrong-type"])

    assert {:error, :unavailable} =
             Redis.enqueue_or_return_existing(request, opts(scope, b_total: 2))

    mismatched_scope = "#{scope}_version"
    seed_unresolved(request, mismatched_scope, "ia02:v99")

    assert {:error, :unavailable} =
             Redis.enqueue_or_return_existing(request, opts(mismatched_scope, b_total: 2))
  end

  test "forged members and identities cannot enter the adapter boundary", %{scope: scope} do
    request = request()

    assert {:error, :invalid_input} =
             Redis.key_set(request.variant_id, request.reservation_key, request.identity_digest,
               scope: scope
             )

    assert {:error, :invalid_input} =
             Redis.key_set(request.variant_id, "client-selected-member", request.identity_digest,
               scope: scope
             )

    assert {:error, :invalid_input} =
             Redis.enqueue_or_return_existing(
               request,
               opts(scope)
               |> Keyword.put(:sequence, 9)
             )

    assert {:error, :invalid_input} =
             Redis.enqueue_or_return_existing(
               request,
               opts(scope)
               |> Keyword.put(:operation_epoch, 9)
             )

    assert {:error, :invalid_input} =
             Redis.enqueue_or_return_existing(
               request,
               opts(scope)
               |> Keyword.put(:operation_id, @operation_id)
             )

    forged = %{request | identity_digest: request.request_fingerprint}

    assert {:error, :invalid_input} =
             Redis.enqueue_or_return_existing(forged, opts(scope, b_total: 2))
  end

  defp request(order_id \\ @order_id, variant_id \\ @variant_id, quantity \\ 1) do
    assert {:ok, request} =
             Request.new(%{order_id: order_id, variant_id: variant_id, quantity: quantity})

    track_request(request, Process.get(:ia02_scope))
    request
  end

  defp opts(scope, overrides \\ []) do
    Keyword.merge(
      [
        hmac_key: @hmac_key,
        scope: scope,
        b_total: 1,
        q_variant_max: 10,
        q_global_max: 20,
        queue_window_ms: 10_000,
        db_window_ms: 2_000,
        lease_window_ms: 3_000,
        safety_margin_ms: 500,
        cleanup_limit: 2
      ],
      overrides
    )
  end

  defp promotion_opts(scope, b_total) do
    [hmac_key: @hmac_key, scope: scope, b_total: b_total, cleanup_limit: 2]
  end

  defp keys_for(request, scope) do
    member = Redis.admission_member(request.identity_digest, @hmac_key)

    assert {:ok, keys} =
             Redis.key_set(request.variant_id, member, request.identity_digest, scope: scope)

    track_keys(keys)
    keys
  end

  defp track_request(request, scope) when is_binary(scope) do
    member = Redis.admission_member(request.identity_digest, @hmac_key)

    assert {:ok, keys} =
             Redis.key_set(request.variant_id, member, request.identity_digest, scope: scope)

    track_keys(keys)
  end

  defp track_keys(keys) do
    on_exit(fn -> cleanup_test_redis([keys]) end)
  end

  defp redis(command), do: Redix.command(RedixClient.connection_name(), command)

  defp hgetall(key) do
    assert {:ok, values} = redis(["HGETALL", key])

    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [field, value] -> {field, value} end)
  end

  defp assert_queue_indexes(keys, member) do
    assert redis(["ZSCORE", keys.variant_queue_order, member]) |> elem(0) == :ok
    assert redis(["ZSCORE", keys.global_queue_dispatch, member]) |> elem(0) == :ok
    assert redis(["ZSCORE", keys.global_queue_expiry, member]) |> elem(0) == :ok
    assert redis(["ZCARD", keys.variant_queue_order]) == {:ok, 1}
    assert redis(["ZCARD", keys.global_queue_dispatch]) == {:ok, 1}
    assert redis(["ZCARD", keys.global_queue_expiry]) == {:ok, 1}
  end

  defp force_expired_queued(request, scope) do
    keys = keys_for(request, scope)
    member = Redis.admission_member(request.identity_digest, @hmac_key)
    {:ok, [seconds, microseconds]} = redis(["TIME"])

    expired_at =
      String.to_integer(seconds) * 1_000 +
        div(String.to_integer(microseconds), 1_000) -
        1

    assert {:ok, 0} =
             redis([
               "HSET",
               keys.request_meta,
               "queue_deadline_ms",
               Integer.to_string(expired_at)
             ])

    assert {:ok, 0} = redis(["ZADD", keys.global_queue_expiry, expired_at, member])
  end

  defp shorten_evidence_ttl(request, scope, ttl_ms) do
    keys = keys_for(request, scope)
    assert {:ok, 1} = redis(["PEXPIRE", keys.request_meta, Integer.to_string(ttl_ms)])
    assert {:ok, 1} = redis(["PEXPIRE", keys.reservation_fence, Integer.to_string(ttl_ms)])
  end

  defp scores_for(flattened) do
    flattened
    |> Enum.chunk_every(2)
    |> Enum.map(fn [_member, score] -> String.to_integer(score) end)
  end

  defp delete_active(request, scope) do
    keys = keys_for(request, scope)
    member = Redis.admission_member(request.identity_digest, @hmac_key)
    assert {:ok, 1} = redis(["DEL", keys.variant_active])
    assert {:ok, 1} = redis(["ZREM", keys.global_active_expiry, member])
  end

  defp cleanup_test_redis(cleanup_keys) do
    assert length(cleanup_keys) <= @max_test_cleanup_records

    case cleanup_keys do
      [] ->
        :ok

      _ ->
        cleanup_keys
        |> Enum.group_by(& &1.global_sequence)
        |> Enum.each(fn {_global_sequence, group} ->
          per_record_keys =
            Enum.flat_map(group, fn keys ->
              [
                keys.variant_queue_order,
                keys.variant_active,
                keys.request_meta,
                keys.reservation_fence
              ]
            end)

          [first_keys | _] = group

          global_keys = [
            first_keys.global_sequence,
            first_keys.global_queue_dispatch,
            first_keys.global_queue_expiry,
            first_keys.global_active_expiry
          ]

          keys = Enum.uniq(per_record_keys ++ global_keys)
          assert {:ok, deleted_count} = redis(["DEL" | keys])
          assert deleted_count <= length(keys)
          assert {:ok, 0} = redis(["EXISTS" | keys])
        end)
    end
  end

  defp seed_unresolved(request, scope, schema \\ Redis.record_version()) do
    keys = keys_for(request, scope)
    member = Redis.admission_member(request.identity_digest, @hmac_key)
    operation_epoch = "7"
    {:ok, variant_hex} = Redis.normalize_variant_key(request.variant_id)

    assert {:ok, _} =
             redis([
               "HSET",
               keys.request_meta,
               "schema_version",
               schema,
               "state",
               "UNRESOLVED",
               "identity_digest",
               request.identity_digest,
               "variant_hex",
               variant_hex,
               "member",
               member,
               "request_fingerprint",
               request.request_fingerprint,
               "operation_id",
               @operation_id,
               "operation_epoch",
               operation_epoch,
               "sequence",
               "0",
               "queue_deadline_ms",
               "",
               "db_window_ms",
               "2000",
               "lease_window_ms",
               "3000",
               "safety_margin_ms",
               "500",
               "db_deadline_ms",
               "",
               "lease_deadline_ms",
               "",
               "lease_token",
               "",
               "owner_epoch",
               "",
               "metadata_ttl_seconds",
               "60"
             ])

    assert {:ok, _} =
             redis([
               "HSET",
               keys.reservation_fence,
               "schema_version",
               schema,
               "state",
               "UNRESOLVED",
               "identity_digest",
               request.identity_digest,
               "variant_hex",
               variant_hex,
               "member",
               member,
               "request_fingerprint",
               request.request_fingerprint,
               "operation_id",
               @operation_id,
               "operation_epoch",
               operation_epoch
             ])
  end
end
