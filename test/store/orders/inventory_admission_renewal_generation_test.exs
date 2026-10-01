defmodule Store.Orders.InventoryAdmissionRenewalGenerationTest do
  use ExUnit.Case, async: false

  alias Store.Orders.InventoryAdmission
  alias Store.Orders.InventoryAdmission.{Lease, Operation, Request}
  alias Store.Orders.InventoryAdmission.Redis
  alias Store.Support.Errors.Error
  alias Store.Support.RateLimit.RedixClient

  @order_id "018ecb40-c457-73e6-a400-000398daddd7"
  @variant_id "018ecb40-c457-73e6-a400-000398daddd9"
  @collection_attempt_id "018ecb40-c457-73e6-a400-000398dadda2"
  @generation_id "018ecb40-c457-73e6-a400-000398dadda3"
  @other_generation_id "018ecb40-c457-73e6-a400-000398dadda4"
  @uuid_v4 "550e8400-e29b-41d4-a716-446655440000"
  @hmac_key "renewal-generation-test-only-key"

  setup do
    {:ok,
     scope:
       "renewal_generation_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"}
  end

  test "generic construction keeps its canonical key and rejects renewal identity input" do
    assert {:ok, generic} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: 2})

    assert generic.reservation_key == "order:#{@order_id}:sku:#{@variant_id}"

    assert {:error, :unknown_request_key} =
             Request.new(%{
               order_id: @order_id,
               variant_id: @variant_id,
               quantity: 2,
               collection_attempt_id: @collection_attempt_id,
               reservation_generation_id: @generation_id
             })
  end

  test "renewal constructor derives exact key and stable identity evidence" do
    assert {:ok, request} = renewal_request()
    assert {:ok, replay} = renewal_request()

    assert request.reservation_key ==
             "order:#{@order_id}:sku:#{@variant_id}:renewal_collection:" <>
               "#{@collection_attempt_id}:generation:#{@generation_id}"

    assert request.identity_digest == replay.identity_digest
    assert request.request_fingerprint == replay.request_fingerprint

    assert {:ok, different_generation} = renewal_request(@other_generation_id)
    refute request.identity_digest == different_generation.identity_digest
    refute request.request_fingerprint == different_generation.request_fingerprint
  end

  test "renewal constructor normalizes UUIDs but rejects malformed identities" do
    assert {:ok, uppercase} =
             Request.new_renewal_generation(
               String.upcase(@order_id),
               String.upcase(@variant_id),
               String.upcase(@collection_attempt_id),
               String.upcase(@generation_id),
               2
             )

    assert uppercase.order_id == @order_id
    assert uppercase.variant_id == @variant_id
    assert uppercase.reservation_key == elem(renewal_request(), 1).reservation_key

    assert {:error, :invalid_collection_attempt_id} =
             Request.new_renewal_generation(
               @order_id,
               @variant_id,
               "not-a-uuid",
               @generation_id,
               2
             )

    assert {:error, :invalid_collection_attempt_id} =
             Request.new_renewal_generation(
               @order_id,
               @variant_id,
               @uuid_v4,
               @generation_id,
               2
             )

    assert {:error, :invalid_reservation_generation_id} =
             Request.new_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               "not-a-uuid",
               2
             )
  end

  test "renewal constructor rejects raw key injection and unknown options" do
    assert {:error, :reservation_key_is_server_derived} =
             Request.new_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @generation_id,
               2,
               reservation_key: "caller-selected"
             )

    assert {:error, :unknown_request_key} =
             Request.new_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @generation_id,
               2,
               client_clock: 10
             )
  end

  test "canonical key classifier distinguishes generic, generation, and invalid keys" do
    assert {:ok, {:generic, %{order_id: @order_id, variant_id: @variant_id}}} =
             Request.classify_reservation_key("order:#{@order_id}:sku:#{@variant_id}")

    assert {:ok,
            {:renewal_generation,
             %{
               order_id: @order_id,
               variant_id: @variant_id,
               collection_attempt_id: @collection_attempt_id,
               reservation_generation_id: @generation_id
             }}} =
             Request.classify_reservation_key(elem(renewal_request(), 1).reservation_key)

    assert {:error, :invalid_reservation_key} =
             Request.classify_reservation_key(
               "order:#{@order_id}:sku:#{@variant_id}:renewal_collection:"
             )

    assert {:error, :reservation_key_not_normalized} =
             Request.classify_reservation_key(
               "order:#{String.upcase(@order_id)}:sku:#{@variant_id}"
             )
  end

  test "operation and lease retain the exact generation reservation key" do
    {:ok, request} = renewal_request()
    facts = reservation_facts(request.reservation_key)

    assert {:ok, pre} =
             Operation.Pre.new(%{
               reservation: :absent,
               inventory: inventory_facts(%{reserved_count: 0, version: 1})
             })

    assert {:ok, post} =
             Operation.Post.new(%{
               reservation: facts,
               inventory: inventory_facts(%{reserved_count: 2, version: 2})
             })

    assert {:ok, operation} =
             Operation.new(request,
               pre: pre,
               post: post,
               deadline: %{
                 db_deadline: 200,
                 lease_deadline: 220,
                 recovery_deadline: 260,
                 safety_margin: 10
               }
             )

    assert operation.order_id == @order_id
    assert operation.variant_id == @variant_id
    assert operation.reservation_key == request.reservation_key
    assert operation.post.reservation.reservation_key == request.reservation_key

    assert {:error, _reason} =
             Operation.new(request,
               pre: pre,
               post: %{
                 post
                 | reservation: reservation_facts("order:#{@order_id}:sku:#{@variant_id}")
               },
               deadline: %{
                 db_deadline: 200,
                 lease_deadline: 220,
                 recovery_deadline: 260,
                 safety_margin: 10
               }
             )

    assert {:ok, lease} =
             Lease.new(%{
               admission_member: String.duplicate("a", 64),
               variant_id: @variant_id,
               reservation_key: request.reservation_key,
               lease_token: "opaque-lease-token",
               owner_epoch: 1,
               identity_digest: request.identity_digest,
               db_deadline: 200,
               lease_deadline: 220,
               safety_margin: 10
             })

    assert lease.reservation_key == request.reservation_key

    assert {:error, _reason} =
             Lease.new(%{
               admission_member: String.duplicate("a", 64),
               variant_id: @variant_id,
               reservation_key: "order:#{@order_id}:sku:#{@variant_id}",
               lease_token: "opaque-lease-token",
               owner_epoch: 1,
               identity_digest: request.identity_digest,
               db_deadline: 200,
               lease_deadline: 220,
               safety_margin: 10
             })
  end

  test "renewal facade persists the exact key and replays legacy generic metadata", %{
    scope: scope
  } do
    assert {:ok, request} = renewal_request()

    assert {:ok, result} =
             InventoryAdmission.reserve_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @generation_id,
               2,
               admission_options(scope)
             )

    assert result.state == :admitted
    refute Map.has_key?(result, :lease_token)
    refute Map.has_key?(result, :owner_epoch)
    refute Map.has_key?(result, :member)

    assert {:ok, keys} =
             Redis.key_set(
               request.variant_id,
               result.reference.member,
               request.identity_digest,
               scope: scope
             )

    assert {:ok, request.reservation_key} ==
             Redix.command(RedixClient.connection_name(), [
               "HGET",
               keys.request_meta,
               "reservation_key"
             ])

    assert {:ok, request.reservation_key} ==
             Redix.command(RedixClient.connection_name(), [
               "HGET",
               keys.reservation_fence,
               "reservation_key"
             ])

    assert {:ok, "ia02:v2"} ==
             Redix.command(RedixClient.connection_name(), [
               "HGET",
               keys.request_meta,
               "schema_version"
             ])

    assert {:ok, generic} =
             Request.new(%{order_id: @order_id, variant_id: @variant_id, quantity: 1})

    assert {:ok, generic_result} =
             InventoryAdmission.reserve(
               %{
                 order_id: @order_id,
                 variant_id: @variant_id,
                 quantity: 1
               },
               admission_options(scope)
             )

    assert {:ok, generic_keys} =
             Redis.key_set(
               generic.variant_id,
               generic_result.reference.member,
               generic.identity_digest,
               scope: scope
             )

    assert {:ok, generic.reservation_key} ==
             Redix.command(RedixClient.connection_name(), [
               "HGET",
               generic_keys.request_meta,
               "reservation_key"
             ])

    assert {:ok, 1} ==
             Redix.command(RedixClient.connection_name(), [
               "HDEL",
               generic_keys.request_meta,
               "reservation_key"
             ])

    assert {:ok, 1} ==
             Redix.command(RedixClient.connection_name(), [
               "HDEL",
               generic_keys.reservation_fence,
               "reservation_key"
             ])

    assert {:ok, replay} =
             InventoryAdmission.reserve(
               %{
                 order_id: @order_id,
                 variant_id: @variant_id,
                 quantity: 1
               },
               admission_options(scope)
             )

    assert replay.state == generic_result.state
    assert replay.operation_id == generic_result.operation_id
  end

  test "Redis status fails closed on key and fingerprint evidence disagreement", %{scope: scope} do
    assert {:ok, request} = renewal_request()

    assert {:ok, result} =
             InventoryAdmission.reserve_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @generation_id,
               2,
               admission_options(scope)
             )

    assert {:ok, keys} =
             Redis.key_set(
               request.variant_id,
               result.reference.member,
               request.identity_digest,
               scope: scope
             )

    assert {:ok, _count} =
             Redix.command(RedixClient.connection_name(), [
               "HSET",
               keys.request_meta,
               "reservation_key",
               "order:#{@order_id}:sku:#{@variant_id}"
             ])

    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNAVAILABLE"}} =
             InventoryAdmission.status(result.reference, lookup_options(scope))

    assert {:ok, second_result} =
             InventoryAdmission.reserve_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @other_generation_id,
               2,
               admission_options(scope)
             )

    assert {:ok, second_keys} =
             Redis.key_set(
               request.variant_id,
               second_result.reference.member,
               second_result.reference.identity_digest,
               scope: scope
             )

    assert {:ok, _count} =
             Redix.command(RedixClient.connection_name(), [
               "HSET",
               second_keys.request_meta,
               "request_fingerprint",
               String.duplicate("f", 64)
             ])

    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNAVAILABLE"}} =
             InventoryAdmission.status(second_result.reference, lookup_options(scope))
  end

  test "renewal evidence with a legacy wire version fails closed", %{scope: scope} do
    assert {:ok, result} =
             InventoryAdmission.reserve_renewal_generation(
               @order_id,
               @variant_id,
               @collection_attempt_id,
               @generation_id,
               2,
               admission_options(scope)
             )

    assert {:ok, keys} =
             Redis.key_set(
               @variant_id,
               result.reference.member,
               result.reference.identity_digest,
               scope: scope
             )

    assert {:ok, _count} =
             Redix.command(RedixClient.connection_name(), [
               "HSET",
               keys.request_meta,
               "schema_version",
               "ia02:v1"
             ])

    assert {:ok, _count} =
             Redix.command(RedixClient.connection_name(), [
               "HSET",
               keys.reservation_fence,
               "schema_version",
               "ia02:v1"
             ])

    assert {:error, %Error{code: "INVENTORY_ADMISSION_UNAVAILABLE"}} =
             InventoryAdmission.status(result.reference, lookup_options(scope))
  end

  defp renewal_request(generation_id \\ @generation_id) do
    Request.new_renewal_generation(
      @order_id,
      @variant_id,
      @collection_attempt_id,
      generation_id,
      2
    )
  end

  defp reservation_facts(reservation_key) do
    assert {:ok, facts} =
             Operation.ReservationFacts.new(%{
               id: "018ecb40-c457-73e6-a400-000398dadda5",
               quantity: 2,
               state: :active,
               reservation_key: reservation_key,
               expires_at: ~U[2026-01-01 00:15:00Z],
               consumed_at: nil,
               expired_at: nil,
               cancelled_at: nil,
               version: 1
             })

    facts
  end

  defp inventory_facts(attrs) do
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

  defp admission_options(scope) do
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
    ]
  end

  defp lookup_options(scope), do: [hmac_key: @hmac_key, scope: scope]
end
