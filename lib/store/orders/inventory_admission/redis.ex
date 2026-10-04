defmodule Store.Orders.InventoryAdmission.Redis do
  @moduledoc """
  Bounded Redis coordination primitive for the IA-02 admission boundary.

  Redis stores only ephemeral admission coordination. It does not store stock,
  availability, reservation outcomes, or any other durable inventory fact.

  Every key used by an atomic operation is derived by this module and supplied
  explicitly as an `EVAL` key. Lua never constructs a key from a member or a
  Redis reply. The common hash tag therefore remains reviewable and valid for a
  Redis Cluster script.
  """

  alias Store.Orders.InventoryAdmission.{Reference, Request}
  alias Store.Support.ID.UUIDv7
  alias Store.Support.RateLimit.RedixClient

  @namespace_version "v1"
  @record_version "ia02:v1"
  @renewal_record_version "ia02:v2"
  @default_scope "default"
  @key_prefix_fallback "store"
  @k_v 1
  @shared_fence_target_max 500
  @shared_terminal_retention_ms 86_400_000
  @slice2_record_version "ia04:v1"

  @member_regex ~r/\A[0-9a-f]{64}\z/
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @variant_hex_regex ~r/\A[0-9a-f]{32}\z/
  @scope_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/
  @version_regex ~r/\Av[0-9]+\z/

  @wire_states %{
    "REQUESTED" => :requested,
    "QUEUED" => :queued,
    "ADMITTED" => :admitted,
    "RESERVING" => :reserving,
    "UNKNOWN_DB_OUTCOME" => :unknown_db_outcome,
    "RECOVERING" => :recovering,
    "UNRESOLVED" => :unresolved,
    "COMPLETED" => :completed,
    "REJECTED" => :rejected,
    "EXPIRED" => :expired,
    "ABANDONED" => :abandoned
  }

  @allowed_enqueue_options [
    :hmac_key,
    :scope,
    :b_total,
    :q_variant_max,
    :q_global_max,
    :queue_window_ms,
    :db_window_ms,
    :lease_window_ms,
    :safety_margin_ms,
    :cleanup_limit,
    :metadata_retention_ms
  ]

  @allowed_promotion_options [:hmac_key, :scope, :b_total, :cleanup_limit]
  @allowed_slice2_options [:hmac_key, :scope, :b_total]
  @allowed_shared_options [:hmac_key, :scope, :metadata_retention_ms, :fence_ttl_ms]
  @reply_field_count 14

  # KEYS[1..8] are always the same explicit ownership set:
  # sequence, variant queue, global dispatch, global queued expiry, variant
  # active, global active expiry, request metadata, reservation fence.
  @enqueue_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA02_UNAVAILABLE"}
  end

  local function busy()
    return {"IA02_BUSY"}
  end

  local function mismatch()
    return {"IA02_MISMATCH"}
  end

  local function frozen()
    return {"IA02_FROZEN"}
  end

  local function known_state(state)
    return state == "REQUESTED"
      or state == "QUEUED"
      or state == "ADMITTED"
      or state == "RESERVING"
      or state == "UNKNOWN_DB_OUTCOME"
      or state == "RECOVERING"
      or state == "UNRESOLVED"
      or state == "COMPLETED"
      or state == "REJECTED"
      or state == "EXPIRED"
      or state == "ABANDONED"
  end

  local function reply(tag, meta)
    return {
      tag,
      meta[2],
      meta[5],
      meta[4],
      meta[3],
      meta[6],
      meta[7],
      tostring(meta[8]),
      meta[9] or "0",
      meta[10] or "",
      meta[14] or "",
      meta[15] or "",
      meta[13] or "",
      meta[17] or "",
      meta[16] or ""
    }
  end

  local function server_now_ms()
    local now_reply = redis.pcall("TIME")

    if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
      return nil
    end

    local now_seconds = tonumber(now_reply[1])
    local now_microseconds = tonumber(now_reply[2])

    if now_seconds == nil or now_microseconds == nil then
      return nil
    end

    return now_seconds * 1000 + math.floor(now_microseconds / 1000)
  end

  local function metadata_values()
    local values = redis.pcall(
      "HMGET",
      KEYS[7],
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "sequence",
      "queue_deadline_ms",
      "db_window_ms",
      "lease_window_ms",
      "safety_margin_ms",
      "db_deadline_ms",
      "lease_deadline_ms",
      "lease_token",
      "owner_epoch",
      "metadata_ttl_seconds",
      "terminal_retention_ms",
      "reservation_key"
    )

    if failed(values) then
      return nil
    end

    return values
  end

  local function fence_values()
    local values = redis.pcall(
      "HMGET",
      KEYS[8],
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "reservation_key"
    )

    if failed(values) then
      return nil
    end

    return values
  end

  local function has_orphaned_member(member)
    local variant_queue_score = redis.pcall("ZSCORE", KEYS[2], member)
    local global_dispatch_score = redis.pcall("ZSCORE", KEYS[3], member)
    local global_queue_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)
    local global_active_score = redis.pcall("ZSCORE", KEYS[6], member)
    local active_member = redis.pcall("HGET", KEYS[5], "member")

    if failed(variant_queue_score)
      or failed(global_dispatch_score)
      or failed(global_queue_expiry_score)
      or failed(global_active_score)
      or failed(active_member) then
      return nil
    end

    return variant_queue_score ~= false
      or global_dispatch_score ~= false
      or global_queue_expiry_score ~= false
      or global_active_score ~= false
      or active_member == member
  end

  local function legacy_generic_key(key)
    if type(key) ~= "string" then
      return false
    end

    local order_id, variant_id = string.match(key, "^order:([^:]+):sku:([^:]+)$")
    return order_id ~= nil and #order_id == 36 and #variant_id == 36
  end

  local function reservation_key_matches(metadata_key, fence_key, expected_key)
    if metadata_key == expected_key and fence_key == expected_key then
      return true
    end

    return metadata_key == false and fence_key == false and legacy_generic_key(expected_key)
  end

  local function validate_existing(meta, fence, schema, identity, variant_hex, member, reservation_key)
    if meta == nil or fence == nil then
      return false
    end

    if meta[1] ~= schema
      or fence[1] ~= schema
      or meta[2] ~= fence[2]
      or meta[3] ~= identity
      or fence[3] ~= identity
      or meta[4] ~= variant_hex
      or fence[4] ~= variant_hex
      or meta[5] ~= member
      or fence[5] ~= member
      or meta[6] ~= fence[6]
      or meta[7] ~= fence[7]
      or meta[8] ~= fence[8]
      or not reservation_key_matches(meta[20], fence[9], reservation_key)
      or meta[6] == false
      or meta[7] == false
      or meta[8] == false
      or not known_state(meta[2]) then
      return false
    end

    return true
  end

  local function existing_indexes_valid(meta)
    if meta[2] == "QUEUED" then
      local variant_score = redis.pcall("ZSCORE", KEYS[2], meta[5])
      local dispatch_score = redis.pcall("ZSCORE", KEYS[3], meta[5])
      local expiry_score = redis.pcall("ZSCORE", KEYS[4], meta[5])
      local active_score = redis.pcall("ZSCORE", KEYS[6], meta[5])
      local active_member = redis.pcall("HGET", KEYS[5], "member")

      if failed(variant_score)
        or failed(dispatch_score)
        or failed(expiry_score)
        or failed(active_score)
        or failed(active_member) then
        return false
      end

      return variant_score ~= false
        and dispatch_score ~= false
        and expiry_score ~= false
        and active_score == false
        and active_member ~= meta[5]
        and tonumber(variant_score) == tonumber(meta[9])
        and tonumber(dispatch_score) == tonumber(meta[9])
        and tonumber(expiry_score) == tonumber(meta[10])
    end

    if meta[2] == "ADMITTED" then
      local active_values = redis.pcall(
        "HMGET",
        KEYS[5],
        "schema_version",
        "state",
        "member",
        "variant_hex",
        "identity_digest",
        "request_fingerprint",
        "operation_id",
        "operation_epoch",
        "lease_token",
        "owner_epoch",
        "db_deadline_ms",
        "lease_deadline_ms",
        "safety_margin_ms",
        "reservation_key"
      )
      local active_score = redis.pcall("ZSCORE", KEYS[6], meta[5])

      if failed(active_values) or failed(active_score) then
        return false
      end

      return active_values[1] == meta[1]
        and active_values[2] == "ADMITTED"
        and active_values[3] == meta[5]
        and active_values[4] == meta[4]
        and active_values[5] == meta[3]
        and active_values[6] == meta[6]
        and active_values[7] == meta[7]
        and active_values[8] == meta[8]
        and active_values[9] == meta[16]
        and active_values[10] == meta[17]
        and active_values[11] == meta[14]
        and active_values[12] == meta[15]
        and active_values[13] == meta[13]
        and active_values[14] == meta[20]
        and active_score ~= false
        and tonumber(active_score) == tonumber(meta[15])
    end

    return true
  end

  local function expire_queued(meta)
    local terminal_retention_ms = tonumber(meta[19])
    if terminal_retention_ms == nil or terminal_retention_ms < 1 then
      return false
    end

    redis.call("ZREM", KEYS[2], meta[5])
    redis.call("ZREM", KEYS[3], meta[5])
    redis.call("ZREM", KEYS[4], meta[5])
    redis.call("HSET", KEYS[7], "state", "EXPIRED")
    redis.call("HSET", KEYS[8], "state", "EXPIRED")
    redis.call("PEXPIRE", KEYS[7], terminal_retention_ms)
    redis.call("PEXPIRE", KEYS[8], terminal_retention_ms)
    meta[2] = "EXPIRED"
    return true
  end

  local function preflight()
    local sequence_value = redis.pcall("GET", KEYS[1])
    local variant_queue_count = redis.pcall("ZCARD", KEYS[2])
    local global_dispatch_count = redis.pcall("ZCARD", KEYS[3])
    local global_queue_expiry_count = redis.pcall("ZCARD", KEYS[4])
    local global_active_count = redis.pcall("ZCARD", KEYS[6])
    local metadata_length = redis.pcall("HLEN", KEYS[7])
    local fence_length = redis.pcall("HLEN", KEYS[8])
    local active_length = redis.pcall("HLEN", KEYS[5])
    local active_values = redis.pcall(
      "HMGET",
      KEYS[5],
      "schema_version",
      "state",
      "member",
      "variant_hex",
      "identity_digest",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "lease_token",
      "owner_epoch",
      "db_deadline_ms",
      "lease_deadline_ms",
      "safety_margin_ms",
      "reservation_key"
    )

    if failed(sequence_value)
      or failed(variant_queue_count)
      or failed(global_dispatch_count)
      or failed(global_queue_expiry_count)
      or failed(global_active_count)
      or failed(metadata_length)
      or failed(fence_length)
      or failed(active_length)
      or failed(active_values) then
      return nil
    end

    if sequence_value ~= false and tonumber(sequence_value) == nil then
      return nil
    end

    return {
      sequence_value,
      variant_queue_count,
      global_dispatch_count,
      global_queue_expiry_count,
      global_active_count,
      metadata_length,
      fence_length,
      active_length,
      active_values
    }
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local operation_id = ARGV[6]
  local lease_token = ARGV[7]
  local b_total = tonumber(ARGV[8])
  local q_variant_max = tonumber(ARGV[9])
  local q_global_max = tonumber(ARGV[10])
  local queue_window_ms = tonumber(ARGV[11])
  local db_window_ms = tonumber(ARGV[12])
  local lease_window_ms = tonumber(ARGV[13])
  local safety_margin_ms = tonumber(ARGV[14])
  local metadata_ttl_seconds = tonumber(ARGV[15])
  local terminal_retention_ms = tonumber(ARGV[16])
  local reservation_key = ARGV[17]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or operation_id == nil
    or lease_token == nil
    or b_total == nil
    or q_variant_max == nil
    or q_global_max == nil
    or queue_window_ms == nil
    or db_window_ms == nil
    or lease_window_ms == nil
    or safety_margin_ms == nil
    or metadata_ttl_seconds == nil
    or terminal_retention_ms == nil
    or reservation_key == nil
    or b_total < 1
    or q_variant_max < 0
    or q_global_max < 0
    or queue_window_ms < 1
    or db_window_ms < 1
    or lease_window_ms < db_window_ms + safety_margin_ms
    or metadata_ttl_seconds < 1
    or terminal_retention_ms < 1 then
    return unavailable()
  end

  local preflight_values = preflight()
  if preflight_values == nil then
    return unavailable()
  end

  local sequence_value = preflight_values[1]
  local variant_queue_count = preflight_values[2]
  local global_dispatch_count = preflight_values[3]
  local global_queue_expiry_count = preflight_values[4]
  local global_active_count = preflight_values[5]
  local metadata_length = preflight_values[6]
  local fence_length = preflight_values[7]
  local active_length = preflight_values[8]
  local active_values = preflight_values[9]

  if global_dispatch_count ~= global_queue_expiry_count then
    return unavailable()
  end

  if active_length > 0 and (active_values[1] == false or active_values[2] == false) then
    return unavailable()
  end

  local metadata = metadata_values()
  local fence = fence_values()
  if metadata == nil or fence == nil then
    return unavailable()
  end

  local metadata_state = metadata[2]
  local fence_state = fence[2]
  local now_ms = nil

  if metadata_state == false and fence_state == false then
    if metadata_length ~= 0 or fence_length ~= 0 then
      return unavailable()
    end

    local orphaned = has_orphaned_member(member)
    if orphaned == nil or orphaned then
      return unavailable()
    end
  elseif metadata_state == false or fence_state == false then
    return unavailable()
  elseif not validate_existing(metadata, fence, schema, identity, variant_hex, member, reservation_key) then
    return unavailable()
  else
    if metadata_state == "QUEUED" then
      local queue_deadline_ms = tonumber(metadata[10])
      local terminal_retention_ms = tonumber(metadata[19])
      now_ms = server_now_ms()

      if queue_deadline_ms == nil or terminal_retention_ms == nil or now_ms == nil then
        return unavailable()
      end

      if now_ms >= queue_deadline_ms then
        if not existing_indexes_valid(metadata) then
          return unavailable()
        end

        if not expire_queued(metadata) then
          return unavailable()
        end

        metadata_state = "EXPIRED"
      end
    end

    if metadata_state == "EXPIRED"
      and (tonumber(metadata[19]) == nil or tonumber(metadata[19]) < 1) then
      return unavailable()
    end

    if metadata_state == "UNRESOLVED" then
      return frozen()
    end

    if metadata[6] == fingerprint then
      if not existing_indexes_valid(metadata) then
        return unavailable()
      end

      return reply("IA02_EXISTING", metadata)
    end

    if metadata_state == "QUEUED"
      or metadata_state == "ADMITTED"
      or metadata_state == "RESERVING"
      or metadata_state == "UNKNOWN_DB_OUTCOME"
      or metadata_state == "RECOVERING"
      or metadata_state == "REQUESTED" then
      return mismatch()
    end

    return frozen()
  end

  if now_ms == nil then
    now_ms = server_now_ms()
  end

  if now_ms == nil then
    return unavailable()
  end
  local active_state = active_values[2]
  local active_member = active_values[3]
  local variant_available = active_state == false

  if active_state == false and active_member ~= false then
    return unavailable()
  end

  if active_state ~= false then
    if (active_values[1] ~= "ia02:v1" and active_values[1] ~= "ia02:v2")
      or active_member == false
      or active_values[4] == false
      or active_values[5] == false
      or active_values[6] == false
      or active_values[7] == false
      or active_values[8] == false
      or active_values[9] == false
      or active_values[10] == false
      or active_values[11] == false
      or active_values[12] == false
      or active_values[13] == false
      or not known_state(active_state) then
      return unavailable()
    end
  end

  local global_available = global_active_count < b_total

  if variant_available and global_available and variant_queue_count == 0 then
    local generation_reply = redis.pcall("INCR", KEYS[1])
    if failed(generation_reply) or generation_reply == false then
      return unavailable()
    end

    local operation_epoch = tonumber(generation_reply)
    if operation_epoch == nil or operation_epoch < 1 then
      return unavailable()
    end

    local db_deadline_ms = now_ms + db_window_ms
    local lease_deadline_ms = now_ms + lease_window_ms

    redis.call(
      "HSET",
      KEYS[8],
      "schema_version", schema,
      "state", "ADMITTED",
      "identity_digest", identity,
      "variant_hex", variant_hex,
      "member", member,
      "request_fingerprint", fingerprint,
      "operation_id", operation_id,
      "operation_epoch", operation_epoch,
      "reservation_key", reservation_key
    )

    redis.call(
      "HSET",
      KEYS[7],
      "schema_version", schema,
      "state", "ADMITTED",
      "identity_digest", identity,
      "variant_hex", variant_hex,
      "member", member,
      "request_fingerprint", fingerprint,
      "operation_id", operation_id,
      "operation_epoch", operation_epoch,
      "reservation_key", reservation_key,
      "sequence", "0",
      "queue_deadline_ms", "",
      "db_window_ms", db_window_ms,
      "lease_window_ms", lease_window_ms,
      "safety_margin_ms", safety_margin_ms,
      "db_deadline_ms", db_deadline_ms,
      "lease_deadline_ms", lease_deadline_ms,
      "lease_token", lease_token,
      "owner_epoch", operation_epoch,
      "metadata_ttl_seconds", metadata_ttl_seconds,
      "terminal_retention_ms", terminal_retention_ms
    )

    redis.call(
      "HSET",
      KEYS[5],
      "schema_version", schema,
      "state", "ADMITTED",
      "member", member,
      "variant_hex", variant_hex,
      "identity_digest", identity,
      "request_fingerprint", fingerprint,
      "operation_id", operation_id,
      "operation_epoch", operation_epoch,
      "reservation_key", reservation_key,
      "lease_token", lease_token,
      "owner_epoch", operation_epoch,
      "db_deadline_ms", db_deadline_ms,
      "lease_deadline_ms", lease_deadline_ms,
      "safety_margin_ms", safety_margin_ms
    )

    redis.call("ZADD", KEYS[6], lease_deadline_ms, member)
    redis.call("EXPIRE", KEYS[7], metadata_ttl_seconds)
    redis.call("EXPIRE", KEYS[8], metadata_ttl_seconds)

    return {
      "IA02_ADMITTED",
      "ADMITTED",
      member,
      variant_hex,
      identity,
      fingerprint,
      operation_id,
      tostring(operation_epoch),
      "0",
      "",
      tostring(db_deadline_ms),
      tostring(lease_deadline_ms),
      tostring(safety_margin_ms),
      tostring(operation_epoch),
      lease_token
    }
  end

  if variant_queue_count >= q_variant_max or global_dispatch_count >= q_global_max then
    return busy()
  end

  local sequence_reply = redis.pcall("INCR", KEYS[1])
  if failed(sequence_reply) or sequence_reply == nil then
    return unavailable()
  end

  local queue_deadline_ms = now_ms + queue_window_ms
  local operation_epoch = tonumber(sequence_reply)
  if operation_epoch == nil or operation_epoch < 1 then
    return unavailable()
  end

  redis.call(
    "HSET",
    KEYS[8],
    "schema_version", schema,
    "state", "QUEUED",
    "identity_digest", identity,
    "variant_hex", variant_hex,
    "member", member,
    "request_fingerprint", fingerprint,
    "operation_id", operation_id,
    "operation_epoch", operation_epoch,
    "reservation_key", reservation_key
  )

  redis.call(
    "HSET",
    KEYS[7],
    "schema_version", schema,
    "state", "QUEUED",
    "identity_digest", identity,
    "variant_hex", variant_hex,
    "member", member,
    "request_fingerprint", fingerprint,
    "operation_id", operation_id,
    "operation_epoch", operation_epoch,
    "reservation_key", reservation_key,
    "sequence", sequence_reply,
    "queue_deadline_ms", queue_deadline_ms,
    "db_window_ms", db_window_ms,
    "lease_window_ms", lease_window_ms,
    "safety_margin_ms", safety_margin_ms,
    "db_deadline_ms", "",
    "lease_deadline_ms", "",
    "lease_token", "",
    "owner_epoch", "",
    "metadata_ttl_seconds", metadata_ttl_seconds,
    "terminal_retention_ms", terminal_retention_ms
  )

  redis.call("ZADD", KEYS[2], sequence_reply, member)
  redis.call("ZADD", KEYS[3], sequence_reply, member)
  redis.call("ZADD", KEYS[4], queue_deadline_ms, member)
  redis.call("EXPIRE", KEYS[7], metadata_ttl_seconds)
  redis.call("EXPIRE", KEYS[8], metadata_ttl_seconds)

  return {
    "IA02_QUEUED",
    "QUEUED",
    member,
      variant_hex,
    identity,
    fingerprint,
    operation_id,
    tostring(operation_epoch),
    tostring(sequence_reply),
    tostring(queue_deadline_ms),
    "",
    "",
    "",
    "",
    ""
  }
  """

  @expire_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA02_UNAVAILABLE"}
  end

  local function already_handled()
    return {"IA02_ALREADY_HANDLED"}
  end

  local function known_state(state)
    return state == "REQUESTED"
      or state == "QUEUED"
      or state == "ADMITTED"
      or state == "RESERVING"
      or state == "UNKNOWN_DB_OUTCOME"
      or state == "RECOVERING"
      or state == "UNRESOLVED"
      or state == "COMPLETED"
      or state == "REJECTED"
      or state == "EXPIRED"
      or state == "ABANDONED"
  end

  local schema = ARGV[1]
  local member = ARGV[2]

  if schema == nil or member == nil then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[6],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "sequence",
    "queue_deadline_ms",
    "terminal_retention_ms",
    "reservation_key"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key"
  )
  local variant_score = redis.pcall("ZSCORE", KEYS[1], member)
  local global_dispatch_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_queue_expiry_score = redis.pcall("ZSCORE", KEYS[3], member)
  local active_member = redis.pcall("HGET", KEYS[4], "member")
  local global_active_score = redis.pcall("ZSCORE", KEYS[5], member)

  if failed(metadata)
    or failed(fence)
    or failed(variant_score)
    or failed(global_dispatch_score)
    or failed(global_queue_expiry_score)
    or failed(active_member)
    or failed(global_active_score) then
    return unavailable()
  end

  if metadata[1] == false
    or fence[1] == false
    or (metadata[1] ~= "ia02:v1" and metadata[1] ~= "ia02:v2")
    or metadata[1] ~= fence[1]
    or metadata[2] == false
    or metadata[2] ~= fence[2]
    or metadata[3] == false
    or metadata[3] ~= fence[3]
    or metadata[4] == false
    or metadata[4] ~= fence[4]
    or metadata[5] ~= member
    or fence[5] ~= member
    or metadata[6] == false
    or metadata[6] ~= fence[6]
    or metadata[7] == false
    or metadata[7] ~= fence[7]
    or metadata[8] == false
    or metadata[8] ~= fence[8]
    or (metadata[1] == "ia02:v2" and (metadata[12] == false or fence[9] == false))
    or ((metadata[12] ~= false or fence[9] ~= false) and metadata[12] ~= fence[9])
    or not known_state(metadata[2]) then
    return unavailable()
  end

  if metadata[2] ~= "QUEUED" then
    if variant_score ~= false
      or global_dispatch_score ~= false
      or global_queue_expiry_score ~= false then
      return unavailable()
    end

    return already_handled()
  end

  if active_member == member or global_active_score ~= false then
    return unavailable()
  end

  local sequence = tonumber(metadata[9])
  local queue_deadline_ms = tonumber(metadata[10])
  local terminal_retention_ms = tonumber(metadata[11])

  if sequence == nil
    or sequence < 1
    or queue_deadline_ms == nil
    or terminal_retention_ms == nil
    or terminal_retention_ms < 1
    or variant_score == false
    or global_dispatch_score == false
    or global_queue_expiry_score == false
    or tonumber(variant_score) ~= sequence
    or tonumber(global_dispatch_score) ~= sequence
    or tonumber(global_queue_expiry_score) ~= queue_deadline_ms then
    return unavailable()
  end

  local now_reply = redis.pcall("TIME")
  if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
    return unavailable()
  end

  local now_seconds = tonumber(now_reply[1])
  local now_microseconds = tonumber(now_reply[2])
  if now_seconds == nil or now_microseconds == nil then
    return unavailable()
  end

  local now_ms = now_seconds * 1000 + math.floor(now_microseconds / 1000)
  if now_ms < queue_deadline_ms then
    return {"IA02_NOT_EXPIRED"}
  end

  redis.call("ZREM", KEYS[1], member)
  redis.call("ZREM", KEYS[2], member)
  redis.call("ZREM", KEYS[3], member)
  redis.call("HSET", KEYS[6], "state", "EXPIRED")
  redis.call("HSET", KEYS[7], "state", "EXPIRED")
  redis.call("PEXPIRE", KEYS[6], terminal_retention_ms)
  redis.call("PEXPIRE", KEYS[7], terminal_retention_ms)

  return {"IA02_EXPIRED"}
  """

  @promotion_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA02_UNAVAILABLE"}
  end

  local function busy()
    return {"IA02_BUSY"}
  end

  local function frozen()
    return {"IA02_FROZEN"}
  end

  local function reply(tag, meta)
    return {
      tag,
      meta[2],
      meta[5],
      meta[4],
      meta[3],
      meta[6],
      meta[7],
      tostring(meta[8]),
      meta[9] or "0",
      meta[10] or "",
      meta[14] or "",
      meta[15] or "",
      meta[13] or "",
      meta[17] or "",
      meta[16] or ""
    }
  end

  local function server_now_ms()
    local now_reply = redis.pcall("TIME")

    if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
      return nil
    end

    local now_seconds = tonumber(now_reply[1])
    local now_microseconds = tonumber(now_reply[2])

    if now_seconds == nil or now_microseconds == nil then
      return nil
    end

    return now_seconds * 1000 + math.floor(now_microseconds / 1000)
  end

  local function known_state(state)
    return state == "REQUESTED"
      or state == "QUEUED"
      or state == "ADMITTED"
      or state == "RESERVING"
      or state == "UNKNOWN_DB_OUTCOME"
      or state == "RECOVERING"
      or state == "UNRESOLVED"
      or state == "COMPLETED"
      or state == "REJECTED"
      or state == "EXPIRED"
      or state == "ABANDONED"
  end

  local function legacy_generic_key(key)
    if type(key) ~= "string" then
      return false
    end

    local order_id, variant_id = string.match(key, "^order:([^:]+):sku:([^:]+)$")
    return order_id ~= nil and #order_id == 36 and #variant_id == 36
  end

  local function reservation_key_matches(metadata_key, fence_key, expected_key)
    if metadata_key == expected_key and fence_key == expected_key then
      return true
    end

    return metadata_key == false and fence_key == false and legacy_generic_key(expected_key)
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local lease_token = ARGV[5]
  local b_total = tonumber(ARGV[6])
  local reservation_key = ARGV[7]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or lease_token == nil
    or b_total == nil
    or reservation_key == nil
    or b_total < 1 then
    return unavailable()
  end

  local sequence_type = redis.pcall("GET", KEYS[1])
  local variant_queue_count = redis.pcall("ZCARD", KEYS[2])
  local global_dispatch_count = redis.pcall("ZCARD", KEYS[3])
  local global_queue_expiry_count = redis.pcall("ZCARD", KEYS[4])
  local global_active_count = redis.pcall("ZCARD", KEYS[6])
  local metadata_length = redis.pcall("HLEN", KEYS[7])
  local fence_length = redis.pcall("HLEN", KEYS[8])
  local active_length = redis.pcall("HLEN", KEYS[5])
  local active_values = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms"
  )
  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "sequence",
    "queue_deadline_ms",
    "db_window_ms",
    "lease_window_ms",
    "safety_margin_ms",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "metadata_ttl_seconds",
    "terminal_retention_ms",
    "reservation_key"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key"
  )

  if failed(sequence_type)
    or failed(variant_queue_count)
    or failed(global_dispatch_count)
    or failed(global_queue_expiry_count)
    or failed(global_active_count)
    or failed(metadata_length)
    or failed(fence_length)
    or failed(active_length)
    or failed(active_values)
    or failed(metadata)
    or failed(fence) then
    return unavailable()
  end

  if sequence_type ~= false and tonumber(sequence_type) == nil then
    return unavailable()
  end

  if global_dispatch_count ~= global_queue_expiry_count then
    return unavailable()
  end

  if active_length > 0 and active_values[1] == false then
    return unavailable()
  end

  if metadata_length == 0
    or fence_length == 0
    or metadata[1] ~= schema
    or fence[1] ~= schema
    or metadata[2] ~= fence[2]
    or metadata[3] ~= identity
    or fence[3] ~= identity
    or metadata[5] ~= member
    or fence[5] ~= member
    or metadata[6] ~= fingerprint
    or fence[6] ~= fingerprint
    or metadata[7] ~= fence[7]
    or metadata[8] ~= fence[8]
    or not reservation_key_matches(metadata[20], fence[9], reservation_key)
    or metadata[4] == false
    or metadata[7] == false
    or metadata[8] == false
    or metadata[19] == false
    or tonumber(metadata[19]) == nil
    or tonumber(metadata[19]) < 1
    or not known_state(metadata[2]) then
    return unavailable()
  end

  if metadata[2] == "EXPIRED" then
    return reply("IA02_EXISTING", metadata)
  end

  if metadata[2] ~= "QUEUED"
    or metadata[9] == false
    or metadata[10] == false
    or metadata[11] == false
    or metadata[12] == false
    or metadata[13] == false
    or metadata[18] == false then
    return unavailable()
  end

  local head = redis.pcall("ZRANGE", KEYS[2], "0", "0")
  local variant_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_dispatch_score = redis.pcall("ZSCORE", KEYS[3], member)
  local global_queue_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)
  local global_active_score = redis.pcall("ZSCORE", KEYS[6], member)

  if failed(head)
    or failed(variant_score)
    or failed(global_dispatch_score)
    or failed(global_queue_expiry_score)
    or failed(global_active_score) then
    return unavailable()
  end

  if #head ~= 1 or head[1] ~= member then
    return busy()
  end

  if variant_score == false
    or global_dispatch_score == false
    or global_queue_expiry_score == false
    or global_active_score ~= false
    or tonumber(variant_score) ~= tonumber(metadata[9])
    or tonumber(global_dispatch_score) ~= tonumber(metadata[9])
    or tonumber(global_queue_expiry_score) ~= tonumber(metadata[10]) then
    return unavailable()
  end

  local now_ms = server_now_ms()
  local queue_deadline_ms = tonumber(metadata[10])
  local terminal_retention_ms = tonumber(metadata[19])
  if now_ms == nil or queue_deadline_ms == nil or terminal_retention_ms == nil then
    return unavailable()
  end

  if terminal_retention_ms < 1 then
    return unavailable()
  end

  if now_ms >= queue_deadline_ms then
    redis.call("ZREM", KEYS[2], member)
    redis.call("ZREM", KEYS[3], member)
    redis.call("ZREM", KEYS[4], member)
    redis.call("HSET", KEYS[7], "state", "EXPIRED")
    redis.call("HSET", KEYS[8], "state", "EXPIRED")
    redis.call("PEXPIRE", KEYS[7], terminal_retention_ms)
    redis.call("PEXPIRE", KEYS[8], terminal_retention_ms)
    metadata[2] = "EXPIRED"
    return reply("IA02_EXISTING", metadata)
  end

  if active_values[1] ~= false then
    if active_values[2] == false
      or active_values[3] == false
      or active_values[4] == false
      or active_values[5] == false
      or active_values[6] == false
      or active_values[7] == false
      or active_values[8] == false
      or active_values[9] == false
      or active_values[10] == false
      or active_values[11] == false
      or active_values[12] == false
      or active_values[13] == false
      or (active_values[1] ~= "ia02:v1" and active_values[1] ~= "ia02:v2")
      or not known_state(active_values[2]) then
      return unavailable()
    end

    return busy()
  end

  if variant_queue_count < 1 or global_active_count >= b_total then
    return busy()
  end

  local db_window_ms = tonumber(metadata[11])
  local lease_window_ms = tonumber(metadata[12])
  local safety_margin_ms = tonumber(metadata[13])
  local metadata_ttl_seconds = tonumber(metadata[18])

  if db_window_ms == nil
    or lease_window_ms == nil
    or safety_margin_ms == nil
    or metadata_ttl_seconds == nil
    or lease_window_ms < db_window_ms + safety_margin_ms then
    return unavailable()
  end

  local db_deadline_ms = now_ms + db_window_ms
  local lease_deadline_ms = now_ms + lease_window_ms

  redis.call("ZREM", KEYS[2], member)
  redis.call("ZREM", KEYS[3], member)
  redis.call("ZREM", KEYS[4], member)

  redis.call(
    "HSET",
    KEYS[8],
    "schema_version", schema,
    "state", "ADMITTED",
    "identity_digest", identity,
    "variant_hex", metadata[4],
    "member", member,
    "request_fingerprint", fingerprint,
    "operation_id", metadata[7],
    "operation_epoch", metadata[8],
    "reservation_key", reservation_key
  )

  redis.call(
    "HSET",
    KEYS[7],
    "schema_version", schema,
    "state", "ADMITTED",
    "identity_digest", identity,
    "variant_hex", metadata[4],
    "member", member,
    "request_fingerprint", fingerprint,
    "operation_id", metadata[7],
    "operation_epoch", metadata[8],
    "reservation_key", reservation_key,
    "sequence", metadata[9],
    "queue_deadline_ms", metadata[10],
    "db_window_ms", db_window_ms,
    "lease_window_ms", lease_window_ms,
    "safety_margin_ms", safety_margin_ms,
    "db_deadline_ms", db_deadline_ms,
    "lease_deadline_ms", lease_deadline_ms,
    "lease_token", lease_token,
    "owner_epoch", metadata[8],
    "metadata_ttl_seconds", metadata_ttl_seconds
  )

  redis.call(
    "HSET",
    KEYS[5],
    "schema_version", schema,
    "state", "ADMITTED",
    "member", member,
    "variant_hex", metadata[4],
    "identity_digest", identity,
    "request_fingerprint", fingerprint,
    "operation_id", metadata[7],
    "operation_epoch", metadata[8],
    "reservation_key", reservation_key,
    "lease_token", lease_token,
    "owner_epoch", metadata[8],
    "db_deadline_ms", db_deadline_ms,
    "lease_deadline_ms", lease_deadline_ms,
    "safety_margin_ms", safety_margin_ms
  )

  redis.call("ZADD", KEYS[6], lease_deadline_ms, member)
  redis.call("EXPIRE", KEYS[7], metadata_ttl_seconds)
  redis.call("EXPIRE", KEYS[8], metadata_ttl_seconds)

  return {
    "IA02_ADMITTED",
    "ADMITTED",
    member,
    metadata[4],
    identity,
    fingerprint,
    metadata[7],
    tostring(metadata[8]),
    metadata[9],
    metadata[10],
    tostring(db_deadline_ms),
    tostring(lease_deadline_ms),
    tostring(safety_margin_ms),
    tostring(metadata[8]),
    lease_token
  }
  """

  @status_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA03_UNAVAILABLE"}
  end

  local function mismatch()
    return {"IA03_MISMATCH"}
  end

  local function frozen()
    return {"IA03_FROZEN"}
  end

  local function known_state(state)
    return state == "REQUESTED"
      or state == "QUEUED"
      or state == "ADMITTED"
      or state == "RESERVING"
      or state == "UNKNOWN_DB_OUTCOME"
      or state == "RECOVERING"
      or state == "UNRESOLVED"
      or state == "COMPLETED"
      or state == "REJECTED"
      or state == "EXPIRED"
      or state == "ABANDONED"
  end

  local function legacy_generic_key(key)
    if type(key) ~= "string" then
      return false
    end

    local order_id, variant_id = string.match(key, "^order:([^:]+):sku:([^:]+)$")
    return order_id ~= nil and #order_id == 36 and #variant_id == 36
  end

  local function reservation_key_matches(metadata_key, fence_key, expected_key)
    if metadata_key == expected_key and fence_key == expected_key then
      return true
    end

    return metadata_key == false and fence_key == false and legacy_generic_key(expected_key)
  end

  local function reply(meta)
    return {
      "IA03_STATUS",
      meta[2],
      meta[5],
      meta[4],
      meta[3],
      meta[6],
      meta[7],
      tostring(meta[8]),
      meta[9] or "0",
      meta[10] or "",
      meta[14] or "",
      meta[15] or "",
      meta[13] or "",
      meta[17] or "",
      meta[16] or ""
    }
  end

  local function server_now_ms()
    local now_reply = redis.pcall("TIME")

    if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
      return nil
    end

    local seconds = tonumber(now_reply[1])
    local microseconds = tonumber(now_reply[2])

    if seconds == nil or microseconds == nil then
      return nil
    end

    return seconds * 1000 + math.floor(microseconds / 1000)
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local operation_id = ARGV[6]
  local operation_epoch = ARGV[7]
  local reservation_key = ARGV[8]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or operation_id == nil
    or operation_epoch == nil
    or reservation_key == nil then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "sequence",
    "queue_deadline_ms",
    "db_window_ms",
    "lease_window_ms",
    "safety_margin_ms",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "metadata_ttl_seconds",
    "terminal_retention_ms",
    "reservation_key"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key"
  )
  local variant_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_dispatch_score = redis.pcall("ZSCORE", KEYS[3], member)
  local global_queue_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)
  local active_member = redis.pcall("HGET", KEYS[5], "member")
  local global_active_score = redis.pcall("ZSCORE", KEYS[6], member)
  local active_values = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms",
    "reservation_key"
  )

  if failed(metadata)
    or failed(fence)
    or failed(variant_score)
    or failed(global_dispatch_score)
    or failed(global_queue_expiry_score)
    or failed(active_member)
    or failed(global_active_score)
    or failed(active_values) then
    return unavailable()
  end

  if metadata[1] == false or fence[1] == false then
    return unavailable()
  end

  if metadata[1] ~= schema
    or fence[1] ~= schema
    or metadata[2] ~= fence[2]
    or metadata[3] ~= identity
    or fence[3] ~= identity
    or metadata[4] ~= variant_hex
    or fence[4] ~= variant_hex
    or metadata[5] ~= member
    or fence[5] ~= member
    or metadata[7] ~= operation_id
    or fence[7] ~= operation_id
    or metadata[8] ~= operation_epoch
    or fence[8] ~= operation_epoch
    or not reservation_key_matches(metadata[20], fence[9], reservation_key)
    or not known_state(metadata[2]) then
    return unavailable()
  end

  if metadata[6] ~= fence[6] then
    return unavailable()
  end

  if metadata[6] ~= fingerprint then
    return mismatch()
  end

  if metadata[2] == "UNRESOLVED" then
    return frozen()
  end

  if metadata[2] == "QUEUED" then
    local sequence = tonumber(metadata[9])
    local queue_deadline_ms = tonumber(metadata[10])
    local retention_ms = tonumber(metadata[19])

    if sequence == nil
      or sequence < 1
      or queue_deadline_ms == nil
      or retention_ms == nil
      or retention_ms < 1
      or variant_score == false
      or global_dispatch_score == false
      or global_queue_expiry_score == false
      or active_member == member
      or global_active_score ~= false
      or tonumber(variant_score) ~= sequence
      or tonumber(global_dispatch_score) ~= sequence
      or tonumber(global_queue_expiry_score) ~= queue_deadline_ms then
      return unavailable()
    end

    local now_ms = server_now_ms()
    if now_ms == nil then
      return unavailable()
    end

    if now_ms >= queue_deadline_ms then
      redis.call("ZREM", KEYS[2], member)
      redis.call("ZREM", KEYS[3], member)
      redis.call("ZREM", KEYS[4], member)
      redis.call("HSET", KEYS[7], "state", "EXPIRED")
      redis.call("HSET", KEYS[8], "state", "EXPIRED")
      redis.call("PEXPIRE", KEYS[7], retention_ms)
      redis.call("PEXPIRE", KEYS[8], retention_ms)
      metadata[2] = "EXPIRED"
    end

    return reply(metadata)
  end

  if metadata[2] == "ADMITTED" then
    if active_member ~= member
      or global_active_score == false
      or active_values[1] ~= schema
      or active_values[2] ~= "ADMITTED"
      or active_values[3] ~= member
      or active_values[4] ~= variant_hex
      or active_values[5] ~= identity
      or active_values[6] ~= fingerprint
      or active_values[7] ~= operation_id
      or active_values[8] ~= operation_epoch
      or active_values[9] ~= metadata[16]
      or active_values[10] ~= metadata[17]
      or active_values[11] ~= metadata[14]
      or active_values[12] ~= metadata[15]
      or active_values[13] ~= metadata[13]
      or active_values[14] ~= metadata[20]
      or tonumber(global_active_score) ~= tonumber(metadata[15]) then
      return unavailable()
    end

    return reply(metadata)
  end

  local terminal_state = metadata[2] == "COMPLETED"
    or metadata[2] == "REJECTED"
    or metadata[2] == "EXPIRED"
    or metadata[2] == "ABANDONED"

  if terminal_state and active_member == member then
    return unavailable()
  end

  if variant_score ~= false
    or global_dispatch_score ~= false
    or global_queue_expiry_score ~= false
    or global_active_score ~= false then
    return unavailable()
  end

  if metadata[2] == "EXPIRED" or metadata[2] == "ABANDONED" then
    local retention_ms = tonumber(metadata[19])
    if retention_ms == nil or retention_ms < 1 then
      return unavailable()
    end
  end

  return reply(metadata)
  """

  @abandon_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA03_UNAVAILABLE"}
  end

  local function mismatch()
    return {"IA03_MISMATCH"}
  end

  local function frozen()
    return {"IA03_FROZEN"}
  end

  local function reply(tag, meta)
    return {
      tag,
      meta[2],
      meta[5],
      meta[4],
      meta[3],
      meta[6],
      meta[7],
      tostring(meta[8]),
      meta[9] or "0",
      meta[10] or "",
      meta[14] or "",
      meta[15] or "",
      meta[13] or "",
      meta[17] or "",
      meta[16] or ""
    }
  end

  local function known_state(state)
    return state == "REQUESTED"
      or state == "QUEUED"
      or state == "ADMITTED"
      or state == "RESERVING"
      or state == "UNKNOWN_DB_OUTCOME"
      or state == "RECOVERING"
      or state == "UNRESOLVED"
      or state == "COMPLETED"
      or state == "REJECTED"
      or state == "EXPIRED"
      or state == "ABANDONED"
  end

  local function legacy_generic_key(key)
    if type(key) ~= "string" then
      return false
    end

    local order_id, variant_id = string.match(key, "^order:([^:]+):sku:([^:]+)$")
    return order_id ~= nil and #order_id == 36 and #variant_id == 36
  end

  local function reservation_key_matches(metadata_key, fence_key, expected_key)
    if metadata_key == expected_key and fence_key == expected_key then
      return true
    end

    return metadata_key == false and fence_key == false and legacy_generic_key(expected_key)
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local operation_id = ARGV[6]
  local operation_epoch = ARGV[7]
  local reservation_key = ARGV[8]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or operation_id == nil
    or operation_epoch == nil
    or reservation_key == nil then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "sequence",
    "queue_deadline_ms",
    "db_window_ms",
    "lease_window_ms",
    "safety_margin_ms",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "metadata_ttl_seconds",
    "terminal_retention_ms",
    "reservation_key"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key"
  )
  local variant_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_dispatch_score = redis.pcall("ZSCORE", KEYS[3], member)
  local global_queue_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)
  local active_member = redis.pcall("HGET", KEYS[5], "member")
  local global_active_score = redis.pcall("ZSCORE", KEYS[6], member)

  if failed(metadata)
    or failed(fence)
    or failed(variant_score)
    or failed(global_dispatch_score)
    or failed(global_queue_expiry_score)
    or failed(active_member)
    or failed(global_active_score) then
    return unavailable()
  end

  if metadata[1] == false or fence[1] == false then
    return unavailable()
  end

  if metadata[1] ~= schema
    or fence[1] ~= schema
    or metadata[2] ~= fence[2]
    or metadata[3] ~= identity
    or fence[3] ~= identity
    or metadata[4] ~= variant_hex
    or fence[4] ~= variant_hex
    or metadata[5] ~= member
    or fence[5] ~= member
    or metadata[7] ~= operation_id
    or fence[7] ~= operation_id
    or metadata[8] ~= operation_epoch
    or fence[8] ~= operation_epoch
    or not reservation_key_matches(metadata[20], fence[9], reservation_key)
    or not known_state(metadata[2]) then
    return unavailable()
  end

  if metadata[6] ~= fence[6] then
    return unavailable()
  end

  if metadata[6] ~= fingerprint then
    return mismatch()
  end

  if metadata[2] == "ABANDONED" then
    if variant_score ~= false
      or global_dispatch_score ~= false
      or global_queue_expiry_score ~= false
      or active_member == member
      or global_active_score ~= false then
      return unavailable()
    end

    if tonumber(metadata[19]) == nil or tonumber(metadata[19]) < 1 then
      return unavailable()
    end

    return reply("IA03_ALREADY_ABANDONED", metadata)
  end

  if metadata[2] ~= "QUEUED" then
    return frozen()
  end

  local sequence = tonumber(metadata[9])
  local queue_deadline_ms = tonumber(metadata[10])
  local retention_ms = tonumber(metadata[19])

  if sequence == nil
    or sequence < 1
    or queue_deadline_ms == nil
    or retention_ms == nil
    or retention_ms < 1
    or variant_score == false
    or global_dispatch_score == false
    or global_queue_expiry_score == false
    or active_member == member
    or global_active_score ~= false
    or tonumber(variant_score) ~= sequence
    or tonumber(global_dispatch_score) ~= sequence
    or tonumber(global_queue_expiry_score) ~= queue_deadline_ms then
    return unavailable()
  end

  redis.call("ZREM", KEYS[2], member)
  redis.call("ZREM", KEYS[3], member)
  redis.call("ZREM", KEYS[4], member)
  redis.call("HSET", KEYS[7], "state", "ABANDONED")
  redis.call("HSET", KEYS[8], "state", "ABANDONED")
  redis.call("PEXPIRE", KEYS[7], retention_ms)
  redis.call("PEXPIRE", KEYS[8], retention_ms)
  metadata[2] = "ABANDONED"

  return reply("IA03_ABANDONED", metadata)
  """

  @claim_reserving_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_UNAVAILABLE"}
  end

  local function mismatch()
    return {"IA04_MISMATCH"}
  end

  local function frozen()
    return {"IA04_FROZEN"}
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local reservation_key = ARGV[6]
  local operation_id = ARGV[7]
  local operation_epoch = ARGV[8]
  local lease_token = ARGV[9]
  local owner_epoch = ARGV[10]
  local db_deadline_ms = ARGV[11]
  local lease_deadline_ms = ARGV[12]
  local safety_margin_ms = ARGV[13]
  local mutation_kind = ARGV[14]
  local desired_quantity = ARGV[15]
  local expiry_policy = ARGV[16]
  local recovery_deadline_ms = ARGV[17]
  local descriptor_version = ARGV[18]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or reservation_key == nil
    or operation_id == nil
    or operation_epoch == nil
    or lease_token == nil
    or owner_epoch == nil
    or db_deadline_ms == nil
    or lease_deadline_ms == nil
    or safety_margin_ms == nil
    or mutation_kind == nil
    or desired_quantity == nil
    or expiry_policy == nil
    or recovery_deadline_ms == nil
    or descriptor_version == nil then
    return unavailable()
  end

  if tonumber(operation_epoch) == nil
    or tonumber(operation_epoch) < 1
    or tonumber(owner_epoch) == nil
    or tonumber(owner_epoch) < 1
    or tonumber(db_deadline_ms) == nil
    or tonumber(lease_deadline_ms) == nil
    or tonumber(safety_margin_ms) == nil
    or tonumber(recovery_deadline_ms) == nil
    or tonumber(recovery_deadline_ms) < tonumber(lease_deadline_ms)
    or tonumber(lease_deadline_ms) < tonumber(db_deadline_ms) + tonumber(safety_margin_ms)
    or tonumber(desired_quantity) == nil
    or tonumber(desired_quantity) < 0 then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "safety_margin_ms",
    "metadata_ttl_seconds",
    "reservation_key",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version",
    "terminal_retention_ms",
    "lease_window_ms"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local active = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local global_score = redis.pcall("ZSCORE", KEYS[6], member)
  local variant_queue_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_queue_score = redis.pcall("ZSCORE", KEYS[3], member)
  local queued_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)

  if failed(metadata)
    or failed(fence)
    or failed(active)
    or failed(global_score)
    or failed(variant_queue_score)
    or failed(global_queue_score)
    or failed(queued_expiry_score) then
    return unavailable()
  end

  local base_matches = metadata[1] == schema
    and fence[1] == schema
    and metadata[3] == identity
    and fence[3] == identity
    and metadata[4] == variant_hex
    and fence[4] == variant_hex
    and metadata[5] == member
    and fence[5] == member
    and metadata[6] == fingerprint
    and fence[6] == fingerprint
    and metadata[7] == operation_id
    and fence[7] == operation_id
    and metadata[8] == operation_epoch
    and fence[8] == operation_epoch
    and metadata[9] == db_deadline_ms
    and metadata[10] == lease_deadline_ms
    and metadata[11] == lease_token
    and metadata[12] == owner_epoch
    and metadata[13] == safety_margin_ms
    and metadata[15] == reservation_key
    and fence[9] == reservation_key
  if not base_matches then
    return mismatch()
  end

  local descriptor_matches = metadata[16] == mutation_kind
    and metadata[17] == desired_quantity
    and metadata[18] == expiry_policy
    and metadata[19] == recovery_deadline_ms
    and metadata[20] == descriptor_version
    and fence[11] == mutation_kind
    and fence[12] == desired_quantity
    and fence[13] == expiry_policy
    and fence[14] == recovery_deadline_ms
    and fence[15] == descriptor_version
    and active[16] == mutation_kind
    and active[17] == desired_quantity
    and active[18] == expiry_policy
    and active[19] == recovery_deadline_ms
    and active[20] == descriptor_version

  local function blank(value)
    return value == false or value == ""
  end

  local descriptor_absent = blank(metadata[16])
    and blank(metadata[17])
    and blank(metadata[18])
    and blank(metadata[19])
    and blank(metadata[20])
    and blank(fence[11])
    and blank(fence[12])
    and blank(fence[13])
    and blank(fence[14])
    and blank(fence[15])
    and blank(active[16])
    and blank(active[17])
    and blank(active[18])
    and blank(active[19])
    and blank(active[20])

  local active_matches = active[1] == schema
    and active[3] == member
    and active[4] == variant_hex
    and active[5] == identity
    and active[6] == fingerprint
    and active[7] == operation_id
    and active[8] == operation_epoch
    and active[9] == lease_token
    and active[10] == owner_epoch
    and active[11] == db_deadline_ms
    and active[12] == lease_deadline_ms
    and active[13] == safety_margin_ms
    and active[14] == reservation_key
    and global_score ~= false
    and tonumber(global_score) == tonumber(lease_deadline_ms)
    and variant_queue_score == false
    and global_queue_score == false
    and queued_expiry_score == false

  if metadata[2] == "RESERVING" then
    if fence[2] ~= "RESERVING"
      or fence[10] ~= "admission"
      or active[2] ~= "RESERVING"
      or not active_matches
      or not descriptor_matches then
      return unavailable()
    end

    return {"IA04_ALREADY_RESERVING", operation_id, operation_epoch}
  end

  if metadata[2] == "ADMITTED" then
    local now_reply = redis.pcall("TIME")
    if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
      return unavailable()
    end

    local now_seconds = tonumber(now_reply[1])
    local now_microseconds = tonumber(now_reply[2])
    if now_seconds == nil or now_microseconds == nil then
      return unavailable()
    end

    local now_ms = now_seconds * 1000 + math.floor(now_microseconds / 1000)
    if now_ms >= tonumber(db_deadline_ms) or now_ms >= tonumber(lease_deadline_ms) then
      return frozen()
    end
  end

  if metadata[2] ~= "ADMITTED"
    or fence[2] ~= "ADMITTED"
    or active[2] ~= "ADMITTED"
    or not active_matches
    or not descriptor_absent
    or variant_queue_score ~= false
    or global_queue_score ~= false
    or queued_expiry_score ~= false then
    return frozen()
  end

  redis.call(
    "HSET",
    KEYS[7],
    "state", "RESERVING",
    "mutation_kind", mutation_kind,
    "desired_quantity", desired_quantity,
    "expiry_policy", expiry_policy,
    "recovery_deadline_ms", recovery_deadline_ms,
    "descriptor_version", descriptor_version
  )
  redis.call(
    "HSET",
    KEYS[8],
    "state", "RESERVING",
    "fence_kind", "admission",
    "mutation_kind", mutation_kind,
    "desired_quantity", desired_quantity,
    "expiry_policy", expiry_policy,
    "recovery_deadline_ms", recovery_deadline_ms,
    "descriptor_version", descriptor_version
  )
  redis.call(
    "HSET",
    KEYS[5],
    "state", "RESERVING",
    "fence_kind", "admission",
    "mutation_kind", mutation_kind,
    "desired_quantity", desired_quantity,
    "expiry_policy", expiry_policy,
    "recovery_deadline_ms", recovery_deadline_ms,
    "descriptor_version", descriptor_version
  )

  return {"IA04_CLAIMED", operation_id, operation_epoch}
  """

  @renew_lease_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_UNAVAILABLE"}
  end

  local function stale()
    return {"IA04_STALE_OWNER"}
  end

  local function deadline_reached()
    return {"IA04_DEADLINE_REACHED"}
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local reservation_key = ARGV[6]
  local operation_id = ARGV[7]
  local operation_epoch = ARGV[8]
  local lease_token = ARGV[9]
  local owner_epoch = ARGV[10]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or reservation_key == nil
    or operation_id == nil
    or operation_epoch == nil
    or lease_token == nil
    or owner_epoch == nil then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "safety_margin_ms",
    "lease_window_ms",
    "reservation_key"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key",
    "fence_kind"
  )
  local active = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms",
    "reservation_key"
  )
  local global_score = redis.pcall("ZSCORE", KEYS[6], member)
  local variant_queue_score = redis.pcall("ZSCORE", KEYS[2], member)
  local global_queue_score = redis.pcall("ZSCORE", KEYS[3], member)
  local queued_expiry_score = redis.pcall("ZSCORE", KEYS[4], member)

  if failed(metadata)
    or failed(fence)
    or failed(active)
    or failed(global_score)
    or failed(variant_queue_score)
    or failed(global_queue_score)
    or failed(queued_expiry_score) then
    return unavailable()
  end

  if metadata[1] ~= schema
    or fence[1] ~= schema
    or metadata[3] ~= identity
    or fence[3] ~= identity
    or metadata[4] ~= variant_hex
    or fence[4] ~= variant_hex
    or metadata[5] ~= member
    or fence[5] ~= member
    or metadata[6] ~= fingerprint
    or fence[6] ~= fingerprint
    or metadata[7] ~= operation_id
    or fence[7] ~= operation_id
    or metadata[8] ~= operation_epoch
    or fence[8] ~= operation_epoch
    or metadata[15] ~= reservation_key
    or fence[9] ~= reservation_key
    or fence[10] ~= "admission"
    or active[1] ~= schema
    or active[3] ~= member
    or active[4] ~= variant_hex
    or active[5] ~= identity
    or active[6] ~= fingerprint
    or active[7] ~= operation_id
    or active[8] ~= operation_epoch
    or active[9] ~= lease_token
    or active[10] ~= owner_epoch
    or active[13] ~= metadata[13]
    or active[14] ~= reservation_key
    or global_score == false
    or tonumber(global_score) ~= tonumber(metadata[10])
    or variant_queue_score ~= false
    or global_queue_score ~= false
    or queued_expiry_score ~= false then
    return stale()
  end

  if metadata[11] ~= lease_token or metadata[12] ~= owner_epoch then
    return stale()
  end

  if metadata[2] ~= "RESERVING" or fence[2] ~= "RESERVING" or active[2] ~= "RESERVING" then
    return {"IA04_NOT_RESERVING"}
  end

  local now_reply = redis.pcall("TIME")
  if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
    return unavailable()
  end

  local seconds = tonumber(now_reply[1])
  local microseconds = tonumber(now_reply[2])
  local db_deadline_ms = tonumber(metadata[9])
  local safety_margin_ms = tonumber(metadata[13])
  local lease_window_ms = tonumber(metadata[14])
  if seconds == nil
    or microseconds == nil
    or db_deadline_ms == nil
    or safety_margin_ms == nil
    or safety_margin_ms < 0
    or lease_window_ms == nil
    or lease_window_ms < 1 then
    return unavailable()
  end

  local now_ms = seconds * 1000 + math.floor(microseconds / 1000)
  if now_ms >= db_deadline_ms then
    return deadline_reached()
  end

  local hard_lease_deadline_ms = db_deadline_ms + safety_margin_ms
  if now_ms + lease_window_ms < hard_lease_deadline_ms then
    return unavailable()
  end

  local next_deadline_ms = math.min(now_ms + lease_window_ms, hard_lease_deadline_ms)
  if next_deadline_ms <= now_ms then
    return deadline_reached()
  end

  redis.call("HSET", KEYS[7], "lease_deadline_ms", next_deadline_ms)
  redis.call("HSET", KEYS[5], "lease_deadline_ms", next_deadline_ms)
  redis.call("ZADD", KEYS[6], next_deadline_ms, member)

  return {"IA04_RENEWED", tostring(next_deadline_ms), tostring(db_deadline_ms)}
  """

  @mark_unknown_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_UNAVAILABLE"}
  end

  local function stale()
    return {"IA04_STALE_OWNER"}
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local reservation_key = ARGV[6]
  local operation_id = ARGV[7]
  local operation_epoch = ARGV[8]
  local lease_token = ARGV[9]
  local owner_epoch = ARGV[10]
  local recovery_deadline_ms = ARGV[11]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or reservation_key == nil
    or operation_id == nil
    or operation_epoch == nil
    or lease_token == nil
    or owner_epoch == nil
    or recovery_deadline_ms == nil
    or tonumber(recovery_deadline_ms) == nil
    or tonumber(recovery_deadline_ms) < 1 then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "safety_margin_ms",
    "terminal_retention_ms",
    "recovery_deadline_ms",
    "reservation_key",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "descriptor_version"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local active = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local global_score = redis.pcall("ZSCORE", KEYS[6], member)

  if failed(metadata) or failed(fence) or failed(active) or failed(global_score) then
    return unavailable()
  end

  local exact_owner = metadata[1] == schema
    and fence[1] == schema
    and metadata[3] == identity
    and fence[3] == identity
    and metadata[4] == variant_hex
    and fence[4] == variant_hex
    and metadata[5] == member
    and fence[5] == member
    and metadata[6] == fingerprint
    and fence[6] == fingerprint
    and metadata[7] == operation_id
    and fence[7] == operation_id
    and metadata[8] == operation_epoch
    and fence[8] == operation_epoch
    and metadata[11] == lease_token
    and metadata[12] == owner_epoch
    and metadata[16] == reservation_key
    and metadata[15] == recovery_deadline_ms
    and fence[9] == reservation_key
    and fence[10] == "admission"
    and fence[11] == metadata[17]
    and fence[12] == metadata[18]
    and fence[13] == metadata[19]
    and fence[14] == metadata[15]
    and fence[15] == metadata[20]
    and active[1] == schema
    and active[3] == member
    and active[4] == variant_hex
    and active[5] == identity
    and active[6] == fingerprint
    and active[7] == operation_id
    and active[8] == operation_epoch
    and active[9] == lease_token
    and active[10] == owner_epoch
    and active[11] == metadata[9]
    and active[12] == metadata[10]
    and active[13] == metadata[13]
    and active[14] == reservation_key
    and active[15] == "admission"
    and active[16] == metadata[17]
    and active[17] == metadata[18]
    and active[18] == metadata[19]
    and active[19] == metadata[15]
    and active[20] == metadata[20]
    and global_score ~= false
    and tonumber(global_score) == tonumber(metadata[10])

  if not exact_owner then
    return stale()
  end

  if metadata[2] == "UNKNOWN_DB_OUTCOME" then
    if fence[2] ~= "UNKNOWN_DB_OUTCOME"
      or active[2] ~= "UNKNOWN_DB_OUTCOME"
      or fence[11] ~= metadata[17]
      or fence[12] ~= metadata[18]
      or fence[13] ~= metadata[19]
      or fence[14] ~= metadata[15]
      or fence[15] ~= metadata[20]
      or active[16] ~= metadata[17]
      or active[17] ~= metadata[18]
      or active[18] ~= metadata[19]
      or active[19] ~= metadata[15]
      or active[20] ~= metadata[20] then
      return unavailable()
    end

    return {"IA04_ALREADY_FENCED", operation_id, operation_epoch}
  end

  if metadata[2] ~= "RESERVING"
    or fence[2] ~= "RESERVING"
    or active[2] ~= "RESERVING" then
    return {"IA04_NOT_RESERVING"}
  end

  local now_reply = redis.pcall("TIME")
  local metadata_pttl = redis.pcall("PTTL", KEYS[7])
  if failed(now_reply)
    or failed(metadata_pttl)
    or now_reply[1] == false
    or now_reply[2] == false then
    return unavailable()
  end

  local seconds = tonumber(now_reply[1])
  local microseconds = tonumber(now_reply[2])
  local metadata_ttl = tonumber(metadata_pttl)
  local terminal_retention_ms = tonumber(metadata[14])
  local recovery_deadline = tonumber(recovery_deadline_ms)
  if seconds == nil
    or microseconds == nil
    or metadata_ttl == nil
    or metadata_ttl == -2
    or terminal_retention_ms == nil
    or terminal_retention_ms < 1
    or recovery_deadline == nil then
    return unavailable()
  end

  local now_ms = seconds * 1000 + math.floor(microseconds / 1000)
  if recovery_deadline <= now_ms then
    return unavailable()
  end

  local required_ttl_ms = recovery_deadline - now_ms + terminal_retention_ms
  if metadata_ttl == -1 or metadata_ttl < required_ttl_ms then
    local renewed = redis.pcall("PEXPIRE", KEYS[7], required_ttl_ms)
    if failed(renewed) or renewed ~= 1 then
      return unavailable()
    end
  end

  local fence_persistent = redis.pcall("PERSIST", KEYS[8])
  local active_persistent = redis.pcall("PERSIST", KEYS[5])
  if failed(fence_persistent) or failed(active_persistent) then
    return unavailable()
  end

  redis.call(
    "HSET",
    KEYS[7],
    "state", "UNKNOWN_DB_OUTCOME",
    "recovery_deadline_ms", recovery_deadline_ms
  )
  redis.call(
    "HSET",
    KEYS[8],
    "state", "UNKNOWN_DB_OUTCOME",
    "fence_kind", "admission",
    "recovery_deadline_ms", recovery_deadline_ms
  )
  redis.call(
    "HSET",
    KEYS[5],
    "state", "UNKNOWN_DB_OUTCOME",
    "fence_kind", "admission",
    "recovery_deadline_ms", recovery_deadline_ms
  )

  return {"IA04_FENCED", operation_id, operation_epoch, recovery_deadline_ms}
  """

  @release_known_outcome_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_UNAVAILABLE"}
  end

  local function stale()
    return {"IA04_STALE_OWNER"}
  end

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local variant_hex = ARGV[5]
  local reservation_key = ARGV[6]
  local operation_id = ARGV[7]
  local operation_epoch = ARGV[8]
  local lease_token = ARGV[9]
  local owner_epoch = ARGV[10]
  local outcome = ARGV[11]
  local b_total = tonumber(ARGV[12])
  local candidate_present = ARGV[13]

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or variant_hex == nil
    or reservation_key == nil
    or operation_id == nil
    or operation_epoch == nil
    or lease_token == nil
    or owner_epoch == nil
    or (outcome ~= "COMPLETED" and outcome ~= "REJECTED")
    or b_total == nil
    or b_total < 1
    or (candidate_present ~= "0" and candidate_present ~= "1") then
    return unavailable()
  end

  local metadata = redis.pcall(
    "HMGET",
    KEYS[7],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "lease_token",
    "owner_epoch",
    "safety_margin_ms",
    "metadata_ttl_seconds",
    "reservation_key",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version",
    "terminal_retention_ms",
    "lease_window_ms",
    "db_window_ms"
  )
  local fence = redis.pcall(
    "HMGET",
    KEYS[8],
    "schema_version",
    "state",
    "identity_digest",
    "variant_hex",
    "member",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local active = redis.pcall(
    "HMGET",
    KEYS[5],
    "schema_version",
    "state",
    "member",
    "variant_hex",
    "identity_digest",
    "request_fingerprint",
    "operation_id",
    "operation_epoch",
    "lease_token",
    "owner_epoch",
    "db_deadline_ms",
    "lease_deadline_ms",
    "safety_margin_ms",
    "reservation_key",
    "fence_kind",
    "mutation_kind",
    "desired_quantity",
    "expiry_policy",
    "recovery_deadline_ms",
    "descriptor_version"
  )
  local global_score = redis.pcall("ZSCORE", KEYS[6], member)

  if failed(metadata) or failed(fence) or failed(active) or failed(global_score) then
    return unavailable()
  end

  local base_matches = metadata[1] == schema
    and fence[1] == schema
    and metadata[3] == identity
    and fence[3] == identity
    and metadata[4] == variant_hex
    and fence[4] == variant_hex
    and metadata[5] == member
    and fence[5] == member
    and metadata[6] == fingerprint
    and fence[6] == fingerprint
    and metadata[7] == operation_id
    and fence[7] == operation_id
    and metadata[8] == operation_epoch
    and fence[8] == operation_epoch
    and metadata[11] == lease_token
    and metadata[12] == owner_epoch
    and metadata[15] == reservation_key
    and fence[9] == reservation_key
  if not base_matches then
    return stale()
  end

  if metadata[2] == "COMPLETED" or metadata[2] == "REJECTED" then
    if metadata[2] ~= outcome
      or fence[2] ~= outcome
      or (active[2] ~= false and active[3] == member)
      or global_score ~= false then
      return stale()
    end

    return {"IA04_ALREADY_RESOLVED", outcome, operation_id, operation_epoch}
  end

  if metadata[2] ~= "RESERVING"
    or fence[2] ~= "RESERVING"
    or fence[10] ~= "admission"
    or active[1] ~= schema
    or active[2] ~= "RESERVING"
    or active[3] ~= member
    or active[4] ~= variant_hex
    or active[5] ~= identity
    or active[6] ~= fingerprint
    or active[7] ~= operation_id
    or active[8] ~= operation_epoch
    or active[9] ~= lease_token
    or active[10] ~= owner_epoch
    or active[11] ~= metadata[9]
    or active[12] ~= metadata[10]
    or active[13] ~= metadata[13]
    or active[14] ~= reservation_key
    or global_score == false
    or tonumber(global_score) ~= tonumber(metadata[10]) then
    return stale()
  end

  local terminal_retention_ms = tonumber(metadata[21])
  local metadata_ttl_seconds = tonumber(metadata[14])
  if terminal_retention_ms == nil
    or terminal_retention_ms < 1
    or metadata_ttl_seconds == nil
    or metadata_ttl_seconds < 1 then
    return unavailable()
  end

  local promoted_member = ""
  local promoted_operation_id = ""
  local promoted_operation_epoch = ""
  local promoted_db_deadline_ms = ""
  local promoted_lease_deadline_ms = ""
  local promoted_lease_token = ""
  local candidate_metadata = nil
  local candidate_identity = nil
  local candidate_variant_hex = nil
  local candidate_member = nil
  local candidate_schema = nil
  local candidate_operation_id = nil
  local candidate_operation_epoch = nil
  local candidate_lease_token = nil
  local candidate_reservation_key = nil
  local candidate_db_deadline_ms = nil
  local candidate_lease_deadline_ms = nil
  local candidate_lease_window_ms = nil
  local candidate_safety_margin_ms = nil
  local candidate_retention_ms = nil
  local candidate_promote = false

  if candidate_present == "1" then
    candidate_member = ARGV[14]
    candidate_identity = ARGV[15]
    candidate_variant_hex = ARGV[16]
    local candidate_fingerprint = ARGV[17]
    candidate_operation_id = ARGV[18]
    candidate_operation_epoch = ARGV[19]
    candidate_lease_token = ARGV[20]
    candidate_reservation_key = ARGV[21]

    if candidate_member == nil
      or candidate_identity == nil
      or candidate_variant_hex == nil
      or candidate_fingerprint == nil
      or candidate_operation_id == nil
      or candidate_operation_epoch == nil
      or candidate_lease_token == nil
      or candidate_reservation_key == nil then
      return unavailable()
    end

    local candidate_queue_score = redis.pcall("ZSCORE", KEYS[9], candidate_member)
    local candidate_dispatch_score = redis.pcall("ZSCORE", KEYS[3], candidate_member)
    local candidate_expiry_score = redis.pcall("ZSCORE", KEYS[4], candidate_member)
    local candidate_queue_head = redis.pcall("ZRANGE", KEYS[9], "0", "0")
    candidate_metadata = redis.pcall(
      "HMGET",
      KEYS[11],
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "sequence",
      "queue_deadline_ms",
      "db_window_ms",
      "lease_window_ms",
      "safety_margin_ms",
      "terminal_retention_ms",
      "reservation_key"
    )
    local candidate_fence = redis.pcall(
      "HMGET",
      KEYS[12],
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "reservation_key"
    )
    local candidate_active_length = redis.pcall("HLEN", KEYS[10])
    local candidate_active = redis.pcall(
      "HMGET",
      KEYS[10],
      "schema_version",
      "state",
      "member",
      "variant_hex",
      "identity_digest",
      "request_fingerprint",
      "operation_id",
      "operation_epoch"
    )
    local candidate_global_active_score = redis.pcall("ZSCORE", KEYS[6], candidate_member)
    local active_count = redis.pcall("ZCARD", KEYS[6])

    if failed(candidate_queue_score)
      or failed(candidate_dispatch_score)
      or failed(candidate_expiry_score)
      or failed(candidate_queue_head)
      or failed(candidate_metadata)
      or failed(candidate_fence)
      or failed(candidate_active_length)
      or failed(candidate_active)
      or failed(candidate_global_active_score)
      or failed(active_count)
      then
      return unavailable()
    end

    candidate_schema = candidate_metadata[1]
    local candidate_active_is_releasing = false
    if candidate_active_length > 0 then
      candidate_active_is_releasing = candidate_active[1] == schema
        and candidate_active[2] == "RESERVING"
        and candidate_active[3] == member
        and candidate_active[4] == variant_hex
        and candidate_active[5] == identity
        and candidate_active[6] == fingerprint
        and candidate_active[7] == operation_id
        and candidate_active[8] == operation_epoch
    end

    if candidate_member == member
      or #candidate_queue_head ~= 1
      or candidate_queue_head[1] ~= candidate_member
      or candidate_queue_score == false
      or candidate_dispatch_score == false
      or candidate_expiry_score == false
      or candidate_global_active_score ~= false
      or (candidate_schema ~= "ia02:v1" and candidate_schema ~= "ia02:v2")
      or candidate_metadata[2] ~= "QUEUED"
      or candidate_metadata[3] ~= candidate_identity
      or candidate_metadata[4] ~= candidate_variant_hex
      or candidate_metadata[5] ~= candidate_member
      or candidate_metadata[6] ~= candidate_fingerprint
      or candidate_metadata[7] ~= candidate_operation_id
      or candidate_metadata[8] ~= candidate_operation_epoch
      or candidate_metadata[15] ~= candidate_reservation_key
      or candidate_fence[1] ~= candidate_schema
      or candidate_fence[2] ~= "QUEUED"
      or candidate_fence[3] ~= candidate_identity
      or candidate_fence[4] ~= candidate_variant_hex
      or candidate_fence[5] ~= candidate_member
      or candidate_fence[6] ~= candidate_fingerprint
      or candidate_fence[7] ~= candidate_operation_id
      or candidate_fence[8] ~= candidate_operation_epoch
      or candidate_fence[9] ~= candidate_reservation_key
      or tonumber(candidate_queue_score) ~= tonumber(candidate_metadata[9])
      or tonumber(candidate_dispatch_score) ~= tonumber(candidate_metadata[9])
      or tonumber(candidate_expiry_score) ~= tonumber(candidate_metadata[10])
      or (candidate_active_length > 0 and not candidate_active_is_releasing) then
      return unavailable()
    end

    local queue_deadline_ms = tonumber(candidate_metadata[10])
    local db_window_ms = tonumber(candidate_metadata[11])
    candidate_lease_window_ms = tonumber(candidate_metadata[12])
    candidate_safety_margin_ms = tonumber(candidate_metadata[13])
    candidate_retention_ms = tonumber(candidate_metadata[14])
    local active_count_number = tonumber(active_count)
    if queue_deadline_ms == nil
      or db_window_ms == nil
      or candidate_lease_window_ms == nil
      or candidate_safety_margin_ms == nil
      or candidate_retention_ms == nil
      or candidate_retention_ms < 1
      or active_count_number == nil
      or active_count_number < 1
      or active_count_number - 1 >= b_total
      or candidate_safety_margin_ms < 0
      or candidate_lease_window_ms < db_window_ms + candidate_safety_margin_ms then
      return unavailable()
    end

    local now_reply = redis.pcall("TIME")
    if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
      return unavailable()
    end

    local seconds = tonumber(now_reply[1])
    local microseconds = tonumber(now_reply[2])
    if seconds == nil or microseconds == nil then
      return unavailable()
    end

    local now_ms = seconds * 1000 + math.floor(microseconds / 1000)
    if now_ms < queue_deadline_ms then
      candidate_db_deadline_ms = now_ms + db_window_ms
      candidate_lease_deadline_ms = now_ms + candidate_lease_window_ms
      candidate_promote = true
    end
  end

  redis.call("HSET", KEYS[7], "state", outcome, "terminal_outcome", outcome)
  redis.call("HSET", KEYS[8], "state", outcome, "fence_kind", "admission", "terminal_outcome", outcome)
  redis.call("ZREM", KEYS[6], member)
  redis.call("DEL", KEYS[5])
  redis.call("PEXPIRE", KEYS[7], terminal_retention_ms)
  redis.call("PEXPIRE", KEYS[8], terminal_retention_ms)

  if candidate_promote then
    redis.call("ZREM", KEYS[9], candidate_member)
    redis.call("ZREM", KEYS[3], candidate_member)
    redis.call("ZREM", KEYS[4], candidate_member)
    redis.call(
      "HSET",
      KEYS[11],
      "state", "ADMITTED",
      "db_deadline_ms", candidate_db_deadline_ms,
      "lease_deadline_ms", candidate_lease_deadline_ms,
      "lease_token", candidate_lease_token,
      "owner_epoch", candidate_operation_epoch
    )
    redis.call("HSET", KEYS[12], "state", "ADMITTED", "fence_kind", "admission")
    redis.call(
      "HSET",
      KEYS[10],
      "schema_version", candidate_schema,
      "state", "ADMITTED",
      "member", candidate_member,
      "variant_hex", candidate_variant_hex,
      "identity_digest", candidate_identity,
      "request_fingerprint", candidate_metadata[6],
      "operation_id", candidate_operation_id,
      "operation_epoch", candidate_operation_epoch,
      "reservation_key", candidate_reservation_key,
      "lease_token", candidate_lease_token,
      "owner_epoch", candidate_operation_epoch,
      "db_deadline_ms", candidate_db_deadline_ms,
      "lease_deadline_ms", candidate_lease_deadline_ms,
      "safety_margin_ms", candidate_safety_margin_ms,
      "fence_kind", "admission"
    )
    redis.call("ZADD", KEYS[6], candidate_lease_deadline_ms, candidate_member)
    redis.call(
      "EXPIRE",
      KEYS[11],
      math.ceil(
        (candidate_retention_ms + candidate_lease_window_ms + candidate_safety_margin_ms) / 1000
      )
    )
    redis.call(
      "EXPIRE",
      KEYS[12],
      math.ceil(
        (candidate_retention_ms + candidate_lease_window_ms + candidate_safety_margin_ms) / 1000
      )
    )
    promoted_member = candidate_member
    promoted_operation_id = candidate_operation_id
    promoted_operation_epoch = candidate_operation_epoch
    promoted_db_deadline_ms = tostring(candidate_db_deadline_ms)
    promoted_lease_deadline_ms = tostring(candidate_lease_deadline_ms)
    promoted_lease_token = candidate_lease_token
  end

  return {
    "IA04_RELEASED",
    outcome,
    operation_id,
    operation_epoch,
    promoted_member,
    promoted_operation_id,
    promoted_operation_epoch,
    promoted_db_deadline_ms,
    promoted_lease_deadline_ms,
    promoted_lease_token
  }
  """

  @shared_acquire_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_SHARED_UNAVAILABLE"}
  end

  local function busy()
    return {"IA04_SHARED_BUSY"}
  end

  local schema = ARGV[1]
  local operation_id = ARGV[2]
  local operation_epoch = ARGV[3]
  local owner_token = ARGV[4]
  local owner_epoch = ARGV[5]
  local mutation_kind = ARGV[6]
  local recovery_deadline_ms = ARGV[7]
  local target_set_digest = ARGV[8]
  local target_count = tonumber(ARGV[9])
  local fence_ttl_ms = tonumber(ARGV[10])

  if schema == nil
    or operation_id == nil
    or operation_epoch == nil
    or owner_token == nil
    or owner_epoch == nil
    or mutation_kind == nil
    or recovery_deadline_ms == nil
    or target_set_digest == nil
    or target_count == nil
    or target_count < 1
    or target_count > 500
    or fence_ttl_ms == nil
    or fence_ttl_ms < 1 then
    return unavailable()
  end

  local now_reply = redis.pcall("TIME")
  if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
    return unavailable()
  end

  local now_seconds = tonumber(now_reply[1])
  local now_microseconds = tonumber(now_reply[2])
  if now_seconds == nil or now_microseconds == nil then
    return unavailable()
  end

  local now_ms = now_seconds * 1000 + math.floor(now_microseconds / 1000)
  local recovery_deadline = tonumber(recovery_deadline_ms)
  if recovery_deadline == nil
    or recovery_deadline <= now_ms
    or recovery_deadline - now_ms > fence_ttl_ms then
    return unavailable()
  end

  local existing_count = 0
  for index = 1, target_count do
    local arg_offset = 10 + (index - 1) * 4
    local member = ARGV[arg_offset + 1]
    local identity = ARGV[arg_offset + 2]
    local variant_hex = ARGV[arg_offset + 3]
    local reservation_key = ARGV[arg_offset + 4]
    local key_offset = (index - 1) * 4
    local active_key = KEYS[key_offset + 1]
    local metadata_key = KEYS[key_offset + 2]
    local admission_fence_key = KEYS[key_offset + 3]
    local shared_fence_key = KEYS[key_offset + 4]
    if member == nil or identity == nil or variant_hex == nil or reservation_key == nil
      or active_key == nil or metadata_key == nil or admission_fence_key == nil
      or shared_fence_key == nil then
      return unavailable()
    end

    local metadata_length = redis.pcall("HLEN", metadata_key)
    local metadata = redis.pcall(
      "HMGET",
      metadata_key,
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "reservation_key"
    )
    local admission_fence_length = redis.pcall("HLEN", admission_fence_key)
    local admission_fence = redis.pcall(
      "HMGET",
      admission_fence_key,
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "request_fingerprint",
      "operation_id",
      "operation_epoch",
      "reservation_key",
      "fence_kind"
    )
    local shared_fence_length = redis.pcall("HLEN", shared_fence_key)
    local shared_fence = redis.pcall(
      "HMGET",
      shared_fence_key,
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "reservation_key",
      "operation_id",
      "operation_epoch",
      "owner_token",
      "owner_epoch",
      "target_set_digest",
      "target_count",
      "mutation_kind",
      "recovery_deadline_ms"
    )
    local active_length = redis.pcall("HLEN", active_key)
    local active_values = redis.pcall("HMGET", active_key, "state", "member")
    local global_score = redis.pcall("ZSCORE", KEYS[target_count * 4 + 1], member)

    if failed(metadata_length)
      or failed(metadata)
      or failed(admission_fence_length)
      or failed(admission_fence)
      or failed(shared_fence_length)
      or failed(shared_fence)
      or failed(active_length)
      or failed(active_values)
      or failed(global_score) then
      return unavailable()
    end

    if active_length > 0 then
      if active_values[1] == false or active_values[2] == false then
        return unavailable()
      end

      return busy()
    end

    if global_score ~= false then
      return busy()
    end

    local metadata_state = metadata[2]
    if metadata_state == false then
      if metadata_length ~= 0 then
        return unavailable()
      end
    elseif metadata[1] == false
      or metadata[3] ~= identity
      or metadata[4] ~= variant_hex
      or metadata[5] ~= member
      or metadata[9] ~= reservation_key then
      return unavailable()
    elseif metadata_state ~= "COMPLETED"
      and metadata_state ~= "REJECTED"
      and metadata_state ~= "EXPIRED"
      and metadata_state ~= "ABANDONED" then
      return busy()
    end

    local admission_state = admission_fence[2]
    if admission_state == false then
      if admission_fence_length ~= 0 then
        return unavailable()
      end
    elseif admission_fence[3] ~= identity
      or admission_fence[4] ~= variant_hex
      or admission_fence[5] ~= member
      or admission_fence[9] ~= reservation_key then
      return unavailable()
    elseif admission_fence[1] == "ia02:v1" or admission_fence[1] == "ia02:v2" then
      if metadata_state == false
        or admission_state ~= metadata_state
        or admission_fence[6] ~= metadata[6]
        or admission_fence[7] ~= metadata[7]
        or admission_fence[8] ~= metadata[8] then
        return unavailable()
      end
    elseif admission_fence[1] == schema and admission_fence[10] == "shared_marker" then
      if admission_state == "SHARED_ACTIVE" or admission_state == "SHARED_UNKNOWN_DB_OUTCOME" then
        -- The shared operation evidence below decides whether this is an exact replay.
      elseif admission_state ~= "SHARED_COMPLETED" and admission_state ~= "SHARED_REJECTED" then
        return unavailable()
      end
    else
      return unavailable()
    end

    local shared_state = shared_fence[2]
    if shared_state == false then
      if shared_fence_length ~= 0 then
        return unavailable()
      end
      if admission_state == "SHARED_ACTIVE" or admission_state == "SHARED_UNKNOWN_DB_OUTCOME" then
        return unavailable()
      end
    else
      if shared_fence[1] ~= schema
        or shared_fence[3] ~= identity
        or shared_fence[4] ~= variant_hex
        or shared_fence[5] ~= member
        or shared_fence[6] ~= reservation_key then
        return unavailable()
      end

      if shared_state == "SHARED_ACTIVE" or shared_state == "SHARED_UNKNOWN_DB_OUTCOME" then
        if shared_fence[7] ~= operation_id
          or shared_fence[8] ~= operation_epoch
          or shared_fence[9] ~= owner_token
          or shared_fence[10] ~= owner_epoch
          or shared_fence[11] ~= target_set_digest
          or shared_fence[12] ~= tostring(target_count)
          or shared_fence[13] ~= mutation_kind
          or shared_fence[14] ~= recovery_deadline_ms then
          return busy()
        end

        existing_count = existing_count + 1
      elseif shared_state ~= "SHARED_COMPLETED" and shared_state ~= "SHARED_REJECTED" then
        return busy()
      end
    end
  end

  if existing_count == target_count then
    return {"IA04_SHARED_ALREADY_ACQUIRED", target_set_digest, tostring(target_count)}
  end

  if existing_count > 0 then
    return busy()
  end

  for index = 1, target_count do
    local arg_offset = 10 + (index - 1) * 4
    local member = ARGV[arg_offset + 1]
    local identity = ARGV[arg_offset + 2]
    local variant_hex = ARGV[arg_offset + 3]
    local reservation_key = ARGV[arg_offset + 4]
    local key_offset = (index - 1) * 4
    local admission_fence_key = KEYS[key_offset + 3]
    local shared_fence_key = KEYS[key_offset + 4]
    local admission_fence_length = redis.pcall("HLEN", admission_fence_key)
    local admission_fence_state = redis.pcall("HGET", admission_fence_key, "state")
    if failed(admission_fence_length) or failed(admission_fence_state) then
      return unavailable()
    end

    redis.call(
      "HSET",
      shared_fence_key,
      "schema_version", schema,
      "state", "SHARED_ACTIVE",
      "identity_digest", identity,
      "variant_hex", variant_hex,
      "member", member,
      "reservation_key", reservation_key,
      "operation_id", operation_id,
      "operation_epoch", operation_epoch,
      "owner_token", owner_token,
      "owner_epoch", owner_epoch,
      "target_set_digest", target_set_digest,
      "target_count", target_count,
      "mutation_kind", mutation_kind,
      "recovery_deadline_ms", recovery_deadline_ms
    )
    redis.call("PERSIST", shared_fence_key)

    if admission_fence_length == 0 then
      redis.call(
        "HSET",
        admission_fence_key,
        "schema_version", schema,
        "state", "SHARED_ACTIVE",
        "fence_kind", "shared_marker",
        "identity_digest", identity,
        "variant_hex", variant_hex,
        "member", member,
        "reservation_key", reservation_key
      )
      redis.call("PERSIST", admission_fence_key)
    elseif admission_fence_state == "SHARED_COMPLETED" or admission_fence_state == "SHARED_REJECTED" then
      redis.call("HSET", admission_fence_key, "state", "SHARED_ACTIVE")
      redis.call("PERSIST", admission_fence_key)
    end
  end

  return {"IA04_SHARED_ACQUIRED", target_set_digest, tostring(target_count)}
  """

  @shared_release_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_SHARED_UNAVAILABLE"}
  end

  local function stale()
    return {"IA04_SHARED_STALE_OWNER"}
  end

  local schema = ARGV[1]
  local operation_id = ARGV[2]
  local operation_epoch = ARGV[3]
  local owner_token = ARGV[4]
  local owner_epoch = ARGV[5]
  local target_set_digest = ARGV[6]
  local target_count = tonumber(ARGV[7])
  local outcome = ARGV[8]
  local fence_ttl_ms = tonumber(ARGV[9])

  if schema == nil
    or operation_id == nil
    or operation_epoch == nil
    or owner_token == nil
    or owner_epoch == nil
    or target_set_digest == nil
    or target_count == nil
    or target_count < 1
    or target_count > 500
    or (outcome ~= "COMPLETED" and outcome ~= "REJECTED")
    or fence_ttl_ms == nil
    or fence_ttl_ms < 1 then
    return unavailable()
  end

  local terminal_count = 0
  local marker_targets = {}
  for index = 1, target_count do
    local arg_offset = 9 + (index - 1) * 4
    local member = ARGV[arg_offset + 1]
    local identity = ARGV[arg_offset + 2]
    local variant_hex = ARGV[arg_offset + 3]
    local reservation_key = ARGV[arg_offset + 4]
    local key_offset = (index - 1) * 4
    local admission_fence_key = KEYS[key_offset + 3]
    local shared_fence_key = KEYS[key_offset + 4]
    local fence = redis.pcall(
      "HMGET",
      shared_fence_key,
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "reservation_key",
      "operation_id",
      "operation_epoch",
      "owner_token",
      "owner_epoch",
      "target_set_digest",
      "target_count"
    )
    local marker = redis.pcall(
      "HMGET",
      admission_fence_key,
      "schema_version",
      "state",
      "fence_kind",
      "identity_digest",
      "variant_hex",
      "member",
      "reservation_key"
    )
    if failed(fence) or failed(marker) then
      return unavailable()
    end

    marker_targets[index] = marker[1] == schema and marker[3] == "shared_marker"

    if marker_targets[index]
      and (marker[4] ~= identity
        or marker[5] ~= variant_hex
        or marker[6] ~= member
        or marker[7] ~= reservation_key) then
      return unavailable()
    end

    if fence[1] ~= schema
      or fence[3] ~= identity
      or fence[4] ~= variant_hex
      or fence[5] ~= member
      or fence[6] ~= reservation_key
      or fence[7] ~= operation_id
      or fence[8] ~= operation_epoch
      or fence[9] ~= owner_token
      or fence[10] ~= owner_epoch
      or fence[11] ~= target_set_digest
      or fence[12] ~= tostring(target_count) then
      return stale()
    end

    if fence[2] == "SHARED_COMPLETED" or fence[2] == "SHARED_REJECTED" then
      if fence[2] ~= "SHARED_" .. outcome then
        return stale()
      end

      if marker_targets[index] and marker[2] ~= fence[2] then
        return unavailable()
      end

      terminal_count = terminal_count + 1
    elseif fence[2] ~= "SHARED_ACTIVE" and fence[2] ~= "SHARED_UNKNOWN_DB_OUTCOME" then
      return stale()
    elseif marker_targets[index] and marker[2] ~= fence[2] then
      return unavailable()
    end
  end

  if terminal_count == target_count then
    return {"IA04_SHARED_ALREADY_RESOLVED", outcome, target_set_digest, tostring(target_count)}
  end

  if terminal_count > 0 then
    return stale()
  end

  for index = 1, target_count do
    local key_offset = (index - 1) * 4
    local admission_fence_key = KEYS[key_offset + 3]
    local shared_fence_key = KEYS[key_offset + 4]
    redis.call(
      "HSET",
      shared_fence_key,
      "state", "SHARED_" .. outcome,
      "fence_kind", "shared",
      "terminal_outcome", outcome
    )
    redis.call("PEXPIRE", shared_fence_key, fence_ttl_ms)
    if marker_targets[index] then
      redis.call("HSET", admission_fence_key, "state", "SHARED_" .. outcome)
      redis.call("PEXPIRE", admission_fence_key, fence_ttl_ms)
    end
  end

  return {"IA04_SHARED_RELEASED", outcome, target_set_digest, tostring(target_count)}
  """

  @shared_unknown_script ~S"""
  local function failed(reply)
    return type(reply) == "table" and reply.err ~= nil
  end

  local function unavailable()
    return {"IA04_SHARED_UNAVAILABLE"}
  end

  local function stale()
    return {"IA04_SHARED_STALE_OWNER"}
  end

  local schema = ARGV[1]
  local operation_id = ARGV[2]
  local operation_epoch = ARGV[3]
  local owner_token = ARGV[4]
  local owner_epoch = ARGV[5]
  local mutation_kind = ARGV[6]
  local target_set_digest = ARGV[7]
  local target_count = tonumber(ARGV[8])
  local recovery_deadline_ms = ARGV[9]
  local fence_ttl_ms = tonumber(ARGV[10])

  if schema == nil
    or operation_id == nil
    or operation_epoch == nil
    or owner_token == nil
    or owner_epoch == nil
    or mutation_kind == nil
    or target_set_digest == nil
    or target_count == nil
    or target_count < 1
    or target_count > 500
    or recovery_deadline_ms == nil
    or tonumber(recovery_deadline_ms) == nil
    or tonumber(recovery_deadline_ms) < 1
    or fence_ttl_ms == nil
    or fence_ttl_ms < 1 then
    return unavailable()
  end

  local now_reply = redis.pcall("TIME")
  if failed(now_reply) or now_reply[1] == false or now_reply[2] == false then
    return unavailable()
  end

  local now_seconds = tonumber(now_reply[1])
  local now_microseconds = tonumber(now_reply[2])
  if now_seconds == nil or now_microseconds == nil then
    return unavailable()
  end

  local now_ms = now_seconds * 1000 + math.floor(now_microseconds / 1000)
  local recovery_deadline = tonumber(recovery_deadline_ms)
  if recovery_deadline == nil
    or recovery_deadline <= now_ms
    or recovery_deadline - now_ms > fence_ttl_ms then
    return unavailable()
  end

  local marker_targets = {}
  for index = 1, target_count do
    local arg_offset = 10 + (index - 1) * 4
    local member = ARGV[arg_offset + 1]
    local identity = ARGV[arg_offset + 2]
    local variant_hex = ARGV[arg_offset + 3]
    local reservation_key = ARGV[arg_offset + 4]
    local key_offset = (index - 1) * 4
    local admission_fence_key = KEYS[key_offset + 3]
    local shared_fence_key = KEYS[key_offset + 4]
    local fence = redis.pcall(
      "HMGET",
      shared_fence_key,
      "schema_version",
      "state",
      "identity_digest",
      "variant_hex",
      "member",
      "reservation_key",
      "operation_id",
      "operation_epoch",
      "owner_token",
      "owner_epoch",
      "target_set_digest",
      "target_count",
      "mutation_kind",
      "recovery_deadline_ms"
    )
    local marker = redis.pcall(
      "HMGET",
      admission_fence_key,
      "schema_version",
      "state",
      "fence_kind",
      "identity_digest",
      "variant_hex",
      "member",
      "reservation_key"
    )
    if failed(fence) or failed(marker) then
      return unavailable()
    end

    marker_targets[index] = marker[1] == schema and marker[3] == "shared_marker"

    if marker_targets[index]
      and (marker[4] ~= identity
        or marker[5] ~= variant_hex
        or marker[6] ~= member
        or marker[7] ~= reservation_key) then
      return unavailable()
    end

    if fence[1] ~= schema
      or fence[3] ~= identity
      or fence[4] ~= variant_hex
      or fence[5] ~= member
      or fence[6] ~= reservation_key
      or fence[7] ~= operation_id
      or fence[8] ~= operation_epoch
      or fence[9] ~= owner_token
      or fence[10] ~= owner_epoch
      or fence[11] ~= target_set_digest
      or fence[12] ~= tostring(target_count)
      or fence[13] ~= mutation_kind
      or fence[14] ~= recovery_deadline_ms then
      return stale()
    end

    if fence[2] ~= "SHARED_ACTIVE" and fence[2] ~= "SHARED_UNKNOWN_DB_OUTCOME" then
      return stale()
    end

    if marker_targets[index]
      and marker[2] ~= fence[2] then
      return unavailable()
    end
  end

  local already_unknown = true
  for index = 1, target_count do
    local fence_key = KEYS[(index - 1) * 4 + 4]
    local state = redis.pcall("HGET", fence_key, "state")
    if failed(state) then
      return unavailable()
    end

    if state ~= "SHARED_UNKNOWN_DB_OUTCOME" then
      already_unknown = false
    end
  end

  if already_unknown then
    return {"IA04_SHARED_ALREADY_FENCED", target_set_digest, tostring(target_count)}
  end

  for index = 1, target_count do
    local key_offset = (index - 1) * 4
    local admission_fence_key = KEYS[key_offset + 3]
    local fence_key = KEYS[key_offset + 4]
    redis.call(
      "HSET",
      fence_key,
      "state", "SHARED_UNKNOWN_DB_OUTCOME",
      "fence_kind", "shared",
      "recovery_deadline_ms", recovery_deadline_ms
    )
    redis.call("PERSIST", fence_key)
    if marker_targets[index] then
      redis.call("HSET", admission_fence_key, "state", "SHARED_UNKNOWN_DB_OUTCOME")
      redis.call("PERSIST", admission_fence_key)
    end
  end

  return {"IA04_SHARED_FENCED", target_set_digest, tostring(target_count)}
  """

  @type status :: :existing | :queued | :admitted | :busy | :mismatch | :frozen
  @type failure :: :unavailable | :invalid_input

  @type admission :: %{
          status: :existing | :queued | :admitted,
          state: Store.Orders.InventoryAdmission.state(),
          member: String.t(),
          variant_id: String.t(),
          variant_hex: String.t(),
          identity_digest: String.t(),
          request_fingerprint: String.t(),
          operation_id: String.t(),
          operation_epoch: pos_integer(),
          sequence: non_neg_integer(),
          queue_deadline_ms: non_neg_integer() | nil,
          db_deadline_ms: non_neg_integer() | nil,
          lease_deadline_ms: non_neg_integer() | nil,
          safety_margin_ms: non_neg_integer() | nil,
          owner_epoch: pos_integer() | nil,
          lease_token: String.t() | nil
        }

  @type result ::
          {:ok, {:existing, admission()}}
          | {:ok, {:queued, admission()}}
          | {:ok, {:admitted, admission()}}
          | {:ok, :busy | :mismatch | :frozen}
          | {:error, failure()}

  @type status_result ::
          {:ok, {:status, admission()}}
          | {:ok, :mismatch | :frozen}
          | {:error, failure()}

  @type abandon_result ::
          {:ok, {:abandoned, admission()}}
          | {:ok, {:already_abandoned, admission()}}
          | {:ok, :mismatch | :frozen}
          | {:error, failure()}

  @spec namespace_version() :: String.t()
  def namespace_version, do: @namespace_version

  @spec record_version() :: String.t()
  def record_version, do: @record_version

  @spec k_v() :: 1
  def k_v, do: @k_v

  @spec common_hash_tag(String.t()) :: String.t()
  def common_hash_tag(scope \\ @default_scope) when is_binary(scope) do
    "{inventory_admission:#{@namespace_version}:#{scope}}"
  end

  @spec normalize_variant_key(term()) :: {:ok, String.t()} | {:error, :invalid_input}
  def normalize_variant_key(value) when is_binary(value) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, Base.encode16(raw16, case: :lower)}
      :error -> {:error, :invalid_input}
    end
  end

  def normalize_variant_key(_value), do: {:error, :invalid_input}

  @spec derive_admission_member(term(), term(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_input}
  def derive_admission_member(identity_digest, hmac_key, key_version \\ @namespace_version) do
    with :ok <- validate_digest(identity_digest),
         :ok <- validate_hmac_key(hmac_key),
         :ok <- validate_version(key_version) do
      data = "inventory_admission_member:" <> key_version <> ":" <> identity_digest
      digest = :crypto.mac(:hmac, :sha256, hmac_key, data)
      {:ok, Base.encode16(digest, case: :lower)}
    else
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :invalid_input}
  end

  @spec admission_member(term(), term(), String.t()) :: String.t() | nil
  def admission_member(identity_digest, hmac_key, key_version \\ @namespace_version) do
    case derive_admission_member(identity_digest, hmac_key, key_version) do
      {:ok, member} -> member
      {:error, :invalid_input} -> nil
    end
  end

  @spec key_set(term(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid_input}
  def key_set(variant_id, member, identity_digest, opts \\ [])

  def key_set(variant_id, member, identity_digest, opts) when is_list(opts) do
    with :ok <- validate_keyword_options(opts, [:scope, :version]),
         {:ok, variant_hex} <- normalize_variant_key(variant_id),
         :ok <- validate_member(member),
         :ok <- validate_digest(identity_digest),
         {:ok, scope} <- fetch_scope(opts),
         {:ok, version} <- fetch_version(opts),
         {:ok, prefix} <- fetch_key_prefix() do
      namespace = "#{prefix}:inventory_admission:#{version}"
      hash_tag = "{inventory_admission:#{version}:#{scope}}"
      base = "#{namespace}:#{hash_tag}"

      {:ok,
       %{
         namespace: namespace,
         hash_tag: hash_tag,
         variant_hex: variant_hex,
         member: member,
         identity_digest: identity_digest,
         global_sequence: "#{base}:global:sequence",
         variant_queue_order: "#{base}:variant:#{variant_hex}:queue_order",
         global_queue_dispatch: "#{base}:global:queue_dispatch",
         global_queue_expiry: "#{base}:global:queue_expiry",
         variant_active: "#{base}:variant:#{variant_hex}:active",
         global_active_expiry: "#{base}:global:active_expiry",
         request_meta: "#{base}:request:#{member}:meta",
         reservation_fence: "#{base}:reservation:#{identity_digest}:mutation_fence",
         shared_mutation_fence: "#{base}:reservation:#{identity_digest}:shared_mutation_fence"
       }}
    else
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  end

  def key_set(_variant_id, _member, _identity_digest, _opts),
    do: {:error, :invalid_input}

  @spec key_names(term(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, :invalid_input}
  def key_names(variant_id, member, identity_digest, opts \\ []) do
    with {:ok, keys} <- key_set(variant_id, member, identity_digest, opts) do
      {:ok, script_keys(keys)}
    end
  end

  @spec enqueue_or_return_existing(Request.t(), keyword()) :: result()
  def enqueue_or_return_existing(request, opts \\ [])

  def enqueue_or_return_existing(%Request{} = request, opts) when is_list(opts) do
    with :ok <- validate_request(request),
         {:ok, options} <- enqueue_options(opts),
         {:ok, member} <- derive_admission_member(request.identity_digest, options.hmac_key),
         {:ok, keys} <-
           key_set(request.variant_id, member, request.identity_digest, scope: options.scope),
         :ok <- cleanup_expired(keys, options.scope, options.cleanup_limit),
         operation_id <- UUIDv7.generate(),
         lease_token <- generate_lease_token(),
         {:ok, reply} <-
           eval(
             @enqueue_script,
             script_keys(keys),
             enqueue_arguments(request, member, operation_id, lease_token, options)
           ) do
      decode_result(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def enqueue_or_return_existing(_request, _opts), do: {:error, :invalid_input}

  @spec promote_queued(Request.t(), keyword()) :: result()
  def promote_queued(request, opts \\ [])

  def promote_queued(%Request{} = request, opts) when is_list(opts) do
    with :ok <- validate_request(request),
         {:ok, options} <- promotion_options(opts),
         {:ok, member} <- derive_admission_member(request.identity_digest, options.hmac_key),
         {:ok, keys} <-
           key_set(request.variant_id, member, request.identity_digest, scope: options.scope),
         :ok <- cleanup_expired(keys, options.scope, options.cleanup_limit),
         lease_token <- generate_lease_token(),
         {:ok, reply} <-
           eval(
             @promotion_script,
             script_keys(keys),
             promotion_arguments(request, member, lease_token, options)
           ) do
      decode_result(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def promote_queued(_request, _opts), do: {:error, :invalid_input}

  @spec status(Reference.t(), keyword()) :: status_result()
  def status(reference, opts \\ [])

  def status(%Reference{} = reference, opts) when is_list(opts) do
    with {:ok, context} <- reference_context(reference, opts),
         {:ok, reply} <-
           eval(
             @status_script,
             script_keys(context.keys),
             reference_arguments(reference, context)
           ) do
      decode_status_result(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def status(_reference, _opts), do: {:error, :invalid_input}

  @spec abandon(Reference.t(), atom(), keyword()) :: abandon_result()
  def abandon(reference, guard, opts \\ [])

  def abandon(%Reference{} = reference, :trusted_pre_reservation_abandonment, opts)
      when is_list(opts) do
    with {:ok, context} <- reference_context(reference, opts),
         {:ok, reply} <-
           eval(
             @abandon_script,
             script_keys(context.keys),
             reference_arguments(reference, context)
           ) do
      decode_abandon_result(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def abandon(_reference, _guard, _opts), do: {:error, :invalid_input}

  @spec claim_reserving(Reference.t(), map(), keyword()) ::
          {:ok, :claimed | :already_reserving | :stale_owner | :frozen} | {:error, failure()}
  def claim_reserving(reference, descriptor, opts \\ [])

  def claim_reserving(%Reference{} = reference, descriptor, opts) when is_list(opts) do
    with {:ok, _options} <- slice2_options(opts),
         {:ok, context} <- reference_context(reference, Keyword.take(opts, [:hmac_key, :scope])),
         {:ok, values} <- claim_descriptor_values(descriptor, reference, context),
         {:ok, reply} <-
           eval(
             @claim_reserving_script,
             script_keys(context.keys),
             claim_arguments(reference, context, values)
           ) do
      decode_claim_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def claim_reserving(_reference, _descriptor, _opts), do: {:error, :invalid_input}

  @spec renew_lease(Reference.t(), map(), keyword()) ::
          {:ok, {:renewed, non_neg_integer()} | :stale_owner | :deadline_reached | :not_reserving}
          | {:error, failure()}
  def renew_lease(reference, lease, opts \\ [])

  def renew_lease(%Reference{} = reference, lease, opts) when is_list(opts) do
    with {:ok, _options} <- slice2_options(opts),
         {:ok, context} <- reference_context(reference, Keyword.take(opts, [:hmac_key, :scope])),
         {:ok, values} <- lease_values(lease, reference, context),
         {:ok, reply} <-
           eval(
             @renew_lease_script,
             script_keys(context.keys),
             lease_arguments(reference, context, values)
           ) do
      decode_renew_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def renew_lease(_reference, _lease, _opts), do: {:error, :invalid_input}

  @spec release_known_outcome(Reference.t(), map(), atom() | String.t(), keyword()) ::
          {:ok, :released | :already_resolved | :stale_owner} | {:error, failure()}
  def release_known_outcome(reference, owner, outcome, opts)

  def release_known_outcome(%Reference{} = reference, owner, outcome, opts)
      when is_list(opts) do
    with {:ok, options} <- slice2_options(opts),
         {:ok, context} <- reference_context(reference, Keyword.take(opts, [:hmac_key, :scope])),
         {:ok, values} <- lease_values(owner, reference, context),
         {:ok, outcome} <- normalize_known_outcome(outcome),
         {:ok, promotion} <- release_promotion_context(context.keys, values.member),
         {:ok, reply} <-
           eval(
             @release_known_outcome_script,
             context.keys |> script_keys() |> Kernel.++(promotion.keys),
             release_arguments(
               reference,
               context,
               Map.put(values, :b_total, options.b_total),
               outcome,
               promotion
             )
           ) do
      decode_release_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def release_known_outcome(_reference, _owner, _outcome, _opts),
    do: {:error, :invalid_input}

  @spec mark_unknown_and_fence(Reference.t(), map(), map(), keyword()) ::
          {:ok, :fenced | :already_fenced | :stale_owner | :not_reserving} | {:error, failure()}
  def mark_unknown_and_fence(reference, owner, descriptor, opts)

  def mark_unknown_and_fence(%Reference{} = reference, owner, descriptor, opts)
      when is_list(opts) do
    with {:ok, context} <- reference_context(reference, opts),
         {:ok, values} <- lease_values(owner, reference, context),
         {:ok, descriptor_values} <- recovery_descriptor_values(descriptor, values),
         {:ok, reply} <-
           eval(
             @mark_unknown_script,
             script_keys(context.keys),
             unknown_arguments(reference, context, descriptor_values)
           ) do
      decode_unknown_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def mark_unknown_and_fence(_reference, _owner, _descriptor, _opts),
    do: {:error, :invalid_input}

  @spec acquire_shared_mutation_fence([map()], map(), keyword()) ::
          {:ok, :acquired | :already_acquired | :busy | :stale_owner} | {:error, failure()}
  def acquire_shared_mutation_fence(targets, owner, opts \\ [])

  def acquire_shared_mutation_fence(targets, owner, opts)
      when is_list(targets) and is_list(opts) do
    with {:ok, options} <- shared_options(opts),
         {:ok, normalized_targets} <- normalize_shared_targets(targets, options),
         {:ok, owner_values} <- shared_owner_values(owner),
         {:ok, reply} <-
           eval(
             @shared_acquire_script,
             shared_script_keys(normalized_targets),
             shared_arguments(normalized_targets, owner_values, options)
           ) do
      decode_shared_acquire_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def acquire_shared_mutation_fence(_targets, _owner, _opts), do: {:error, :invalid_input}

  @spec release_shared_mutation_fence_known_outcome(
          [map()],
          map(),
          atom() | String.t(),
          keyword()
        ) ::
          {:ok, :released | :already_resolved | :stale_owner} | {:error, failure()}
  def release_shared_mutation_fence_known_outcome(targets, owner, outcome, opts)

  def release_shared_mutation_fence_known_outcome(targets, owner, outcome, opts)
      when is_list(targets) and is_list(opts) do
    with {:ok, options} <- shared_options(opts),
         {:ok, normalized_targets} <- normalize_shared_targets(targets, options),
         {:ok, owner_values} <- shared_owner_values(owner),
         {:ok, outcome} <- normalize_known_outcome(outcome),
         {:ok, reply} <-
           eval(
             @shared_release_script,
             shared_script_keys(normalized_targets),
             shared_release_arguments(normalized_targets, owner_values, outcome, options)
           ) do
      decode_shared_release_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  @spec mark_shared_mutation_unknown([map()], map(), keyword()) ::
          {:ok, :fenced | :already_fenced | :stale_owner} | {:error, failure()}
  def mark_shared_mutation_unknown(targets, owner, opts \\ [])

  def mark_shared_mutation_unknown(targets, owner, opts)
      when is_list(targets) and is_list(opts) do
    with {:ok, options} <- shared_options(opts),
         {:ok, normalized_targets} <- normalize_shared_targets(targets, options),
         {:ok, owner_values} <- shared_owner_values(owner),
         {:ok, reply} <-
           eval(
             @shared_unknown_script,
             shared_script_keys(normalized_targets),
             shared_unknown_arguments(normalized_targets, owner_values, options)
           ) do
      decode_shared_unknown_reply(reply)
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def mark_shared_mutation_unknown(_targets, _owner, _opts), do: {:error, :invalid_input}

  defp slice2_options(opts) do
    with :ok <- validate_keyword_options(opts, @allowed_slice2_options),
         {:ok, hmac_key} <- fetch_hmac_key(opts),
         {:ok, scope} <- fetch_scope(opts),
         {:ok, b_total} <- fetch_option_or_default(opts, :b_total, 1) do
      {:ok, %{hmac_key: hmac_key, scope: scope, b_total: b_total}}
    end
  end

  defp shared_options(opts) do
    with :ok <- validate_keyword_options(opts, @allowed_shared_options),
         {:ok, hmac_key} <- fetch_hmac_key(opts),
         {:ok, scope} <- fetch_scope(opts),
         {:ok, metadata_retention_ms} <-
           fetch_option_or_default(opts, :metadata_retention_ms, @shared_terminal_retention_ms),
         {:ok, fence_ttl_ms} <-
           fetch_option_or_default(opts, :fence_ttl_ms, metadata_retention_ms) do
      {:ok,
       %{
         hmac_key: hmac_key,
         scope: scope,
         metadata_retention_ms: metadata_retention_ms,
         fence_ttl_ms: fence_ttl_ms
       }}
    end
  end

  defp descriptor_map(%{__struct__: _module} = descriptor) do
    descriptor_map(Map.from_struct(descriptor))
  end

  defp descriptor_map(descriptor) when is_map(descriptor) do
    deadline = Map.get(descriptor, :deadline)
    mutation = Map.get(descriptor, :mutation)

    descriptor
    |> Map.drop([:__struct__, :order_id, :mutation, :pre, :post, :deadline])
    |> maybe_put(
      :variant_id,
      Map.get(descriptor, :variant_id) || get_field(mutation, :variant_id)
    )
    |> maybe_put(
      :mutation_kind,
      Map.get(descriptor, :mutation_kind) || get_field(mutation, :kind)
    )
    |> maybe_put(
      :desired_quantity,
      Map.get(descriptor, :desired_quantity) || get_field(mutation, :desired_quantity)
    )
    |> maybe_put(
      :expiry_policy,
      Map.get(descriptor, :expiry_policy) || get_field(mutation, :expiry_policy)
    )
    |> maybe_put(
      :db_deadline_ms,
      Map.get(descriptor, :db_deadline_ms) || get_field(deadline, :db_deadline)
    )
    |> maybe_put(
      :lease_deadline_ms,
      Map.get(descriptor, :lease_deadline_ms) || get_field(deadline, :lease_deadline)
    )
    |> maybe_put(
      :safety_margin_ms,
      Map.get(descriptor, :safety_margin_ms) || get_field(deadline, :safety_margin)
    )
    |> maybe_put(
      :recovery_deadline_ms,
      Map.get(descriptor, :recovery_deadline_ms) || get_field(deadline, :recovery_deadline)
    )
  end

  defp descriptor_map(_descriptor), do: :invalid

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_field(nil, _key), do: nil
  defp get_field(%{__struct__: _module} = value, key), do: Map.get(value, key)
  defp get_field(value, key) when is_map(value), do: Map.get(value, key)
  defp get_field(_value, _key), do: nil

  defp claim_descriptor_values(descriptor, %Reference{} = reference, context) do
    descriptor = descriptor_map(descriptor)

    with true <- is_map(descriptor),
         :ok <- validate_descriptor_keys(descriptor),
         {:ok, values} <- descriptor_values(descriptor),
         :ok <- validate_descriptor_identity(values, reference, context) do
      {:ok, values}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp descriptor_values(descriptor) do
    required = [
      :member,
      :variant_id,
      :reservation_key,
      :identity_digest,
      :request_fingerprint,
      :operation_id,
      :operation_epoch,
      :lease_token,
      :owner_epoch,
      :db_deadline_ms,
      :lease_deadline_ms,
      :safety_margin_ms,
      :mutation_kind,
      :desired_quantity,
      :expiry_policy,
      :recovery_deadline_ms
    ]

    if Enum.all?(required, &Map.has_key?(descriptor, &1)) do
      validate_descriptor_values(descriptor)
    else
      {:error, :invalid_input}
    end
  end

  defp validate_descriptor_values(descriptor) do
    with :ok <- validate_member(Map.fetch!(descriptor, :member)),
         {:ok, variant_hex} <- normalize_variant_key(Map.fetch!(descriptor, :variant_id)),
         :ok <- validate_digest(Map.fetch!(descriptor, :identity_digest)),
         :ok <- validate_digest(Map.fetch!(descriptor, :request_fingerprint)),
         :ok <- validate_operation_id(Map.fetch!(descriptor, :operation_id)),
         :ok <- validate_positive_integer(Map.fetch!(descriptor, :operation_epoch)),
         :ok <- validate_token(Map.fetch!(descriptor, :lease_token)),
         :ok <- validate_positive_integer(Map.fetch!(descriptor, :owner_epoch)),
         :ok <- validate_non_negative_integer(Map.fetch!(descriptor, :db_deadline_ms)),
         :ok <- validate_non_negative_integer(Map.fetch!(descriptor, :lease_deadline_ms)),
         :ok <- validate_non_negative_integer(Map.fetch!(descriptor, :safety_margin_ms)),
         :ok <-
           validate_deadline_options(
             Map.fetch!(descriptor, :lease_deadline_ms),
             Map.fetch!(descriptor, :db_deadline_ms),
             Map.fetch!(descriptor, :safety_margin_ms)
           ),
         :ok <- validate_descriptor_text(Map.fetch!(descriptor, :mutation_kind)),
         :ok <- validate_non_negative_integer(Map.fetch!(descriptor, :desired_quantity)),
         :ok <- validate_descriptor_text(Map.fetch!(descriptor, :expiry_policy)),
         :ok <- validate_non_negative_integer(Map.fetch!(descriptor, :recovery_deadline_ms)),
         true <-
           Map.fetch!(descriptor, :recovery_deadline_ms) >=
             Map.fetch!(descriptor, :lease_deadline_ms) do
      {:ok,
       %{
         member: Map.fetch!(descriptor, :member),
         variant_hex: variant_hex,
         variant_id: Map.fetch!(descriptor, :variant_id),
         reservation_key: Map.fetch!(descriptor, :reservation_key),
         identity_digest: Map.fetch!(descriptor, :identity_digest),
         request_fingerprint: Map.fetch!(descriptor, :request_fingerprint),
         operation_id: Map.fetch!(descriptor, :operation_id),
         operation_epoch: Map.fetch!(descriptor, :operation_epoch),
         lease_token: Map.fetch!(descriptor, :lease_token),
         owner_epoch: Map.fetch!(descriptor, :owner_epoch),
         db_deadline_ms: Map.fetch!(descriptor, :db_deadline_ms),
         lease_deadline_ms: Map.fetch!(descriptor, :lease_deadline_ms),
         safety_margin_ms: Map.fetch!(descriptor, :safety_margin_ms),
         mutation_kind: Map.fetch!(descriptor, :mutation_kind),
         desired_quantity: Map.fetch!(descriptor, :desired_quantity),
         expiry_policy: Map.fetch!(descriptor, :expiry_policy),
         recovery_deadline_ms: Map.fetch!(descriptor, :recovery_deadline_ms),
         descriptor_version: Map.get(descriptor, :descriptor_version, @slice2_record_version)
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp validate_descriptor_keys(descriptor) when is_map(descriptor) do
    allowed = [
      :member,
      :variant_id,
      :reservation_key,
      :identity_digest,
      :request_fingerprint,
      :operation_id,
      :operation_epoch,
      :lease_token,
      :owner_epoch,
      :db_deadline_ms,
      :lease_deadline_ms,
      :safety_margin_ms,
      :mutation_kind,
      :desired_quantity,
      :expiry_policy,
      :recovery_deadline_ms,
      :descriptor_version
    ]

    if Enum.all?(Map.keys(descriptor), &(&1 in allowed)), do: :ok, else: {:error, :invalid_input}
  end

  defp validate_descriptor_keys(_descriptor), do: {:error, :invalid_input}

  defp validate_descriptor_identity(values, reference, context) do
    if values.member == context.member and
         values.variant_hex == context.variant_hex and
         values.reservation_key == reference.reservation_key and
         values.identity_digest == reference.identity_digest and
         values.request_fingerprint == reference.request_fingerprint and
         values.operation_id == reference.operation_id and
         values.operation_epoch == reference.operation_epoch do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp lease_values(lease, %Reference{} = reference, context) do
    lease = lease_map(lease)
    descriptor = lease_descriptor(lease, reference, context)

    with {:ok, values} <- descriptor_values(descriptor),
         :ok <- validate_descriptor_identity(values, reference, context) do
      {:ok, values}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp lease_map(%{__struct__: _module} = lease), do: Map.from_struct(lease)
  defp lease_map(lease) when is_map(lease), do: lease
  defp lease_map(_lease), do: %{}

  defp lease_descriptor(lease, %Reference{} = reference, context) do
    lease_deadline_ms = Map.get(lease, :lease_deadline_ms) || Map.get(lease, :lease_deadline)

    %{
      member: Map.get(lease, :member) || Map.get(lease, :admission_member) || context.member,
      variant_id: Map.get(lease, :variant_id, reference.variant_id),
      reservation_key: Map.get(lease, :reservation_key, reference.reservation_key),
      identity_digest: Map.get(lease, :identity_digest, reference.identity_digest),
      request_fingerprint: Map.get(lease, :request_fingerprint, reference.request_fingerprint),
      operation_id: Map.get(lease, :operation_id, reference.operation_id),
      operation_epoch: Map.get(lease, :operation_epoch, reference.operation_epoch),
      lease_token: Map.get(lease, :lease_token),
      owner_epoch: Map.get(lease, :owner_epoch),
      db_deadline_ms: Map.get(lease, :db_deadline_ms) || Map.get(lease, :db_deadline),
      lease_deadline_ms: lease_deadline_ms,
      safety_margin_ms: Map.get(lease, :safety_margin_ms) || Map.get(lease, :safety_margin),
      mutation_kind: Map.get(lease, :mutation_kind, "reserve"),
      desired_quantity: Map.get(lease, :desired_quantity, 0),
      expiry_policy: Map.get(lease, :expiry_policy, "none"),
      recovery_deadline_ms: Map.get(lease, :recovery_deadline_ms, lease_deadline_ms || 0)
    }
  end

  defp recovery_descriptor_values(descriptor, lease_values) do
    descriptor = descriptor_map(descriptor)

    recovery_deadline_ms =
      if is_map(descriptor), do: Map.get(descriptor, :recovery_deadline_ms), else: nil

    if is_integer(recovery_deadline_ms) and recovery_deadline_ms > 0 do
      {:ok, Map.put(lease_values, :recovery_deadline_ms, recovery_deadline_ms)}
    else
      {:error, :invalid_input}
    end
  end

  defp claim_arguments(reference, _context, values) do
    [
      record_version(reference),
      values.identity_digest,
      values.request_fingerprint,
      values.member,
      values.variant_hex,
      values.reservation_key,
      values.operation_id,
      Integer.to_string(values.operation_epoch),
      values.lease_token,
      Integer.to_string(values.owner_epoch),
      Integer.to_string(values.db_deadline_ms),
      Integer.to_string(values.lease_deadline_ms),
      Integer.to_string(values.safety_margin_ms),
      values.mutation_kind,
      Integer.to_string(values.desired_quantity),
      values.expiry_policy,
      Integer.to_string(values.recovery_deadline_ms),
      values.descriptor_version
    ]
  end

  defp lease_arguments(reference, _context, values) do
    [
      record_version(reference),
      values.identity_digest,
      values.request_fingerprint,
      values.member,
      values.variant_hex,
      values.reservation_key,
      values.operation_id,
      Integer.to_string(values.operation_epoch),
      values.lease_token,
      Integer.to_string(values.owner_epoch)
    ]
  end

  defp unknown_arguments(reference, _context, values) do
    [
      record_version(reference),
      values.identity_digest,
      values.request_fingerprint,
      values.member,
      values.variant_hex,
      values.reservation_key,
      values.operation_id,
      Integer.to_string(values.operation_epoch),
      values.lease_token,
      Integer.to_string(values.owner_epoch),
      Integer.to_string(values.recovery_deadline_ms)
    ]
  end

  defp normalize_known_outcome(:completed), do: {:ok, "COMPLETED"}
  defp normalize_known_outcome(:rejected), do: {:ok, "REJECTED"}
  defp normalize_known_outcome("COMPLETED"), do: {:ok, "COMPLETED"}
  defp normalize_known_outcome("REJECTED"), do: {:ok, "REJECTED"}
  defp normalize_known_outcome(_outcome), do: {:error, :invalid_input}

  defp release_promotion_context(keys, releasing_member) do
    with :ok <- validate_member(releasing_member),
         {:ok, candidate_members} <-
           redis_command(["ZRANGE", keys.global_queue_dispatch, "0", "-1"]),
         true <- is_list(candidate_members),
         {:ok, now_ms} <- redis_server_time() do
      discover_release_candidate(keys, candidate_members, releasing_member, now_ms)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp discover_release_candidate(_keys, [], _releasing_member, _now_ms),
    do: {:ok, %{keys: [], present: false}}

  defp discover_release_candidate(keys, [member | rest], releasing_member, now_ms) do
    if member == releasing_member do
      discover_release_candidate(keys, rest, releasing_member, now_ms)
    else
      case promotion_candidate(keys, member, releasing_member, now_ms) do
        {:ok, :blocked} ->
          discover_release_candidate(keys, rest, releasing_member, now_ms)

        {:ok, candidate} ->
          {:ok, candidate}

        {:error, :unavailable} = error ->
          error
      end
    end
  end

  defp promotion_candidate(keys, candidate_member, releasing_member, now_ms) do
    candidate_meta_key = request_meta_key(keys, candidate_member)

    with :ok <- validate_member(candidate_member),
         {:ok,
          [
            candidate_schema,
            "QUEUED",
            candidate_identity,
            candidate_variant_hex,
            candidate_fingerprint,
            candidate_operation_id,
            candidate_operation_epoch,
            candidate_sequence,
            candidate_queue_deadline,
            candidate_reservation_key
          ]} <-
           redis_command([
             "HMGET",
             candidate_meta_key,
             "schema_version",
             "state",
             "identity_digest",
             "variant_hex",
             "request_fingerprint",
             "operation_id",
             "operation_epoch",
             "sequence",
             "queue_deadline_ms",
             "reservation_key"
           ]),
         true <- candidate_schema in [@record_version, @renewal_record_version],
         :ok <- validate_digest(candidate_identity),
         :ok <- validate_variant_hex(candidate_variant_hex),
         :ok <- validate_digest(candidate_fingerprint),
         :ok <- validate_operation_id(candidate_operation_id),
         {:ok, candidate_epoch} <- parse_positive_integer(candidate_operation_epoch),
         {:ok, sequence} <- parse_positive_integer(candidate_sequence),
         {:ok, queue_deadline_ms} <- parse_positive_integer(candidate_queue_deadline),
         true <- is_binary(candidate_reservation_key) and byte_size(candidate_reservation_key) > 0,
         {:ok, candidate_variant_id} <- decode_variant_hex(candidate_variant_hex),
         {:ok, candidate_keys} <-
           key_set(candidate_variant_id, candidate_member, candidate_identity,
             scope: scope_from_keys(keys)
           ),
         {:ok,
          [
            fence_schema,
            "QUEUED",
            fence_identity,
            fence_variant_hex,
            ^candidate_member,
            fence_fingerprint,
            fence_operation_id,
            fence_operation_epoch,
            fence_reservation_key
          ]} <-
           redis_command([
             "HMGET",
             candidate_keys.reservation_fence,
             "schema_version",
             "state",
             "identity_digest",
             "variant_hex",
             "member",
             "request_fingerprint",
             "operation_id",
             "operation_epoch",
             "reservation_key"
           ]),
         true <- fence_schema == candidate_schema,
         true <- fence_identity == candidate_identity,
         true <- fence_variant_hex == candidate_variant_hex,
         true <- fence_fingerprint == candidate_fingerprint,
         true <- fence_operation_id == candidate_operation_id,
         true <- fence_operation_epoch == candidate_operation_epoch,
         true <- fence_reservation_key == candidate_reservation_key,
         {:ok, queue_score} <-
           redis_command(["ZSCORE", candidate_keys.variant_queue_order, candidate_member]),
         {:ok, dispatch_score} <-
           redis_command(["ZSCORE", keys.global_queue_dispatch, candidate_member]),
         {:ok, expiry_score} <-
           redis_command(["ZSCORE", keys.global_queue_expiry, candidate_member]),
         {:ok, queue_head} <-
           redis_command(["ZRANGE", candidate_keys.variant_queue_order, "0", "0"]),
         {:ok, active_length} <- redis_command(["HLEN", candidate_keys.variant_active]),
         {:ok, active} <-
           redis_command([
             "HMGET",
             candidate_keys.variant_active,
             "state",
             "member",
             "variant_hex",
             "identity_digest",
             "request_fingerprint",
             "operation_id",
             "operation_epoch"
           ]),
         {:ok, global_active_score} <-
           redis_command(["ZSCORE", keys.global_active_expiry, candidate_member]) do
      candidate = %{
        keys: keys,
        candidate_keys: candidate_keys,
        meta_key: candidate_meta_key,
        member: candidate_member,
        releasing_member: releasing_member,
        identity_digest: candidate_identity,
        variant_hex: candidate_variant_hex,
        request_fingerprint: candidate_fingerprint,
        operation_id: candidate_operation_id,
        operation_epoch: candidate_epoch,
        reservation_key: candidate_reservation_key,
        sequence: sequence,
        queue_deadline_ms: queue_deadline_ms,
        queue_score: queue_score,
        dispatch_score: dispatch_score,
        expiry_score: expiry_score,
        queue_head: queue_head,
        active_length: active_length,
        active: active,
        global_active_score: global_active_score
      }

      validate_release_candidate(candidate, now_ms)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp validate_release_candidate(candidate, now_ms) do
    cond do
      not release_candidate_indexes_match?(candidate) ->
        {:error, :unavailable}

      candidate.global_active_score != nil ->
        {:error, :unavailable}

      not release_candidate_head_and_live?(candidate, now_ms) ->
        {:ok, :blocked}

      true ->
        validate_release_candidate_active(candidate)
    end
  end

  defp release_candidate_indexes_match?(candidate) do
    candidate.queue_score != nil and candidate.dispatch_score != nil and
      candidate.expiry_score != nil and
      score_matches?(candidate.queue_score, candidate.sequence) and
      score_matches?(candidate.dispatch_score, candidate.sequence) and
      score_matches?(candidate.expiry_score, candidate.queue_deadline_ms)
  end

  defp release_candidate_head_and_live?(candidate, now_ms) do
    candidate.queue_head == [candidate.member] and candidate.queue_deadline_ms > now_ms
  end

  defp validate_release_candidate_active(candidate) do
    case release_candidate_active_state(candidate) do
      :free -> {:ok, release_promotion(candidate)}
      :releasing -> {:ok, release_promotion(candidate)}
      :busy -> {:ok, :blocked}
      :invalid -> {:error, :unavailable}
    end
  end

  defp release_candidate_active_state(%{active_length: 0}), do: :free

  defp release_candidate_active_state(candidate) do
    cond do
      candidate.candidate_keys.variant_active == candidate.keys.variant_active and
          release_active_matches?(
            candidate.active,
            candidate.releasing_member,
            candidate.variant_hex
          ) ->
        :releasing

      Enum.all?(candidate.active, &is_binary/1) ->
        :busy

      true ->
        :invalid
    end
  end

  defp release_active_matches?(
         ["RESERVING", releasing_member, variant_hex | _],
         releasing_member,
         variant_hex
       ),
       do: true

  defp release_active_matches?(_active, _releasing_member, _variant_hex), do: false

  defp release_promotion(candidate) do
    %{
      keys: [
        candidate.candidate_keys.variant_queue_order,
        candidate.candidate_keys.variant_active,
        candidate.meta_key,
        candidate.candidate_keys.reservation_fence
      ],
      present: true,
      member: candidate.member,
      identity_digest: candidate.identity_digest,
      variant_hex: candidate.variant_hex,
      request_fingerprint: candidate.request_fingerprint,
      operation_id: candidate.operation_id,
      operation_epoch: candidate.operation_epoch,
      reservation_key: candidate.reservation_key,
      lease_token: generate_lease_token()
    }
  end

  defp score_matches?(score, expected) when is_binary(score) do
    case Float.parse(score) do
      {value, ""} -> value == expected
      _ -> false
    end
  end

  defp score_matches?(_score, _expected), do: false

  defp scope_from_keys(keys) do
    case Regex.run(~r/\{inventory_admission:[^:]+:([^}]+)\}/, keys.hash_tag) do
      [_, scope] -> scope
      _ -> @default_scope
    end
  end

  defp release_arguments(reference, _context, values, outcome, promotion) do
    promotion_arguments =
      if promotion.present do
        [
          promotion.member,
          promotion.identity_digest,
          promotion.variant_hex,
          promotion.request_fingerprint,
          promotion.operation_id,
          Integer.to_string(promotion.operation_epoch),
          promotion.lease_token,
          promotion.reservation_key
        ]
      else
        []
      end

    [
      record_version(reference),
      values.identity_digest,
      values.request_fingerprint,
      values.member,
      values.variant_hex,
      values.reservation_key,
      values.operation_id,
      Integer.to_string(values.operation_epoch),
      values.lease_token,
      Integer.to_string(values.owner_epoch),
      outcome,
      Integer.to_string(values.b_total),
      if(promotion.present, do: "1", else: "0")
    ] ++ promotion_arguments
  end

  defp shared_owner_values(owner) do
    owner =
      case owner do
        %{__struct__: _module} = value -> Map.from_struct(value)
        value when is_map(value) -> value
        _ -> %{}
      end

    owner_token =
      Map.get(owner, :owner_token) || Map.get(owner, :fence_token) || Map.get(owner, :lease_token)

    with :ok <- validate_operation_id(Map.get(owner, :operation_id)),
         :ok <- validate_positive_integer(Map.get(owner, :operation_epoch)),
         :ok <- validate_token(owner_token),
         :ok <- validate_positive_integer(Map.get(owner, :owner_epoch)),
         :ok <- validate_descriptor_text(Map.get(owner, :mutation_kind)),
         :ok <- validate_non_negative_integer(Map.get(owner, :recovery_deadline_ms)),
         true <- Map.get(owner, :recovery_deadline_ms) > 0 do
      {:ok,
       %{
         operation_id: Map.get(owner, :operation_id),
         operation_epoch: Map.get(owner, :operation_epoch),
         owner_token: owner_token,
         owner_epoch: Map.get(owner, :owner_epoch),
         mutation_kind: Map.get(owner, :mutation_kind),
         recovery_deadline_ms: Map.get(owner, :recovery_deadline_ms)
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp normalize_shared_targets(targets, options) do
    target_count = Enum.count(targets)

    cond do
      target_count < 1 ->
        {:error, :invalid_input}

      target_count > @shared_fence_target_max ->
        {:error, :invalid_input}

      true ->
        normalize_shared_target_list(targets, options)
    end
  end

  defp normalize_shared_target_list(targets, options) do
    case Enum.reduce_while(targets, {:ok, {MapSet.new(), []}}, fn target, state ->
           collect_shared_target(target, options, state)
         end) do
      {:ok, {_seen, normalized}} ->
        ordered = Enum.sort_by(normalized, & &1.sort_key)

        digest_input =
          Enum.map_join(ordered, "\0", &(&1.reservation_key <> "\0" <> &1.identity_digest))

        digest = :crypto.hash(:sha256, digest_input) |> Base.encode16(case: :lower)
        {:ok, %{targets: ordered, digest: digest, count: Enum.count(ordered), options: options}}

      {:error, :invalid_input} ->
        {:error, :invalid_input}
    end
  end

  defp collect_shared_target(target, options, {:ok, {seen, acc}}) do
    case normalize_shared_target(target, options) do
      {:ok, normalized} -> add_shared_target(normalized, seen, acc)
      {:error, :invalid_input} -> {:halt, {:error, :invalid_input}}
    end
  end

  defp add_shared_target(normalized, seen, acc) do
    if MapSet.member?(seen, normalized.reservation_key) do
      {:halt, {:error, :invalid_input}}
    else
      {:cont, {:ok, {MapSet.put(seen, normalized.reservation_key), [normalized | acc]}}}
    end
  end

  defp normalize_shared_target(target, options) do
    target =
      case target do
        %{__struct__: _module} = value -> Map.from_struct(value)
        value when is_map(value) -> value
        _ -> %{}
      end

    allowed = [:reservation_key, :variant_id, :identity_digest, :member]

    with true <- Enum.all?(Map.keys(target), &(&1 in allowed)),
         {:ok, {_kind, identities}} <-
           Request.classify_reservation_key(Map.get(target, :reservation_key)),
         {:ok, variant_hex} <- normalize_variant_key(Map.get(target, :variant_id)),
         true <- identities.variant_id == Map.get(target, :variant_id),
         {:ok, identity_digest} <-
           Request.identity_digest_for_reservation_key(Map.get(target, :reservation_key)),
         true <- identity_digest == Map.get(target, :identity_digest),
         {:ok, member} <- derive_admission_member(identity_digest, options.hmac_key),
         true <- is_nil(Map.get(target, :member)) or Map.get(target, :member) == member,
         {:ok, keys} <-
           key_set(Map.get(target, :variant_id), member, identity_digest, scope: options.scope),
         {:ok, order_raw} <- UUIDv7.decode(identities.order_id),
         {:ok, variant_raw} <- UUIDv7.decode(identities.variant_id),
         {:ok, collection_raw} <- sort_identity_raw(Map.get(identities, :collection_attempt_id)),
         {:ok, generation_raw} <-
           sort_identity_raw(Map.get(identities, :reservation_generation_id)) do
      {:ok,
       %{
         reservation_key: Map.get(target, :reservation_key),
         variant_id: Map.get(target, :variant_id),
         variant_hex: variant_hex,
         identity_digest: identity_digest,
         member: member,
         keys: keys,
         sort_key: {order_raw, variant_raw, collection_raw, generation_raw}
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp sort_identity_raw(nil), do: {:ok, <<>>}
  defp sort_identity_raw(identity), do: UUIDv7.decode(identity)

  defp shared_script_keys(%{targets: targets}) do
    target_keys =
      Enum.flat_map(targets, fn target ->
        [
          target.keys.variant_active,
          target.keys.request_meta,
          target.keys.reservation_fence,
          target.keys.shared_mutation_fence
        ]
      end)

    target_keys ++ [List.first(targets).keys.global_active_expiry]
  end

  defp shared_arguments(%{targets: targets, digest: digest, count: count}, owner, options) do
    [
      @slice2_record_version,
      owner.operation_id,
      Integer.to_string(owner.operation_epoch),
      owner.owner_token,
      Integer.to_string(owner.owner_epoch),
      owner.mutation_kind,
      Integer.to_string(owner.recovery_deadline_ms),
      digest,
      Integer.to_string(count),
      Integer.to_string(options.fence_ttl_ms)
    ] ++ shared_target_arguments(targets)
  end

  defp shared_release_arguments(
         %{targets: targets, digest: digest, count: count},
         owner,
         outcome,
         options
       ) do
    [
      @slice2_record_version,
      owner.operation_id,
      Integer.to_string(owner.operation_epoch),
      owner.owner_token,
      Integer.to_string(owner.owner_epoch),
      digest,
      Integer.to_string(count),
      outcome,
      Integer.to_string(options.fence_ttl_ms)
    ] ++ shared_target_arguments(targets)
  end

  defp shared_unknown_arguments(%{targets: targets, digest: digest, count: count}, owner, options) do
    [
      @slice2_record_version,
      owner.operation_id,
      Integer.to_string(owner.operation_epoch),
      owner.owner_token,
      Integer.to_string(owner.owner_epoch),
      owner.mutation_kind,
      digest,
      Integer.to_string(count),
      Integer.to_string(owner.recovery_deadline_ms),
      Integer.to_string(options.fence_ttl_ms)
    ] ++ shared_target_arguments(targets)
  end

  defp shared_target_arguments(targets) do
    Enum.flat_map(targets, fn target ->
      [target.member, target.identity_digest, target.variant_hex, target.reservation_key]
    end)
  end

  defp decode_claim_reply(["IA04_CLAIMED", _operation_id, _operation_epoch]),
    do: {:ok, :claimed}

  defp decode_claim_reply(["IA04_ALREADY_RESERVING", _operation_id, _operation_epoch]),
    do: {:ok, :already_reserving}

  defp decode_claim_reply(["IA04_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_claim_reply(["IA04_FROZEN"]), do: {:ok, :frozen}
  defp decode_claim_reply(["IA04_MISMATCH"]), do: {:ok, :stale_owner}
  defp decode_claim_reply(["IA04_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_claim_reply(_reply), do: {:error, :unavailable}

  defp decode_renew_reply(["IA04_RENEWED", deadline, _db_deadline]) do
    case parse_non_negative_integer(deadline) do
      {:ok, deadline} -> {:ok, {:renewed, deadline}}
      {:error, :invalid_input} -> {:error, :unavailable}
    end
  end

  defp decode_renew_reply(["IA04_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_renew_reply(["IA04_DEADLINE_REACHED"]), do: {:ok, :deadline_reached}
  defp decode_renew_reply(["IA04_NOT_RESERVING"]), do: {:ok, :not_reserving}
  defp decode_renew_reply(["IA04_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_renew_reply(_reply), do: {:error, :unavailable}

  defp decode_unknown_reply(["IA04_FENCED", _operation_id, _operation_epoch, _deadline]),
    do: {:ok, :fenced}

  defp decode_unknown_reply(["IA04_ALREADY_FENCED", _operation_id, _operation_epoch]),
    do: {:ok, :already_fenced}

  defp decode_unknown_reply(["IA04_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_unknown_reply(["IA04_NOT_RESERVING"]), do: {:ok, :not_reserving}
  defp decode_unknown_reply(["IA04_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_unknown_reply(_reply), do: {:error, :unavailable}

  defp decode_release_reply(["IA04_RELEASED", _outcome | _fields]), do: {:ok, :released}

  defp decode_release_reply(["IA04_ALREADY_RESOLVED", _outcome, _operation_id, _operation_epoch]),
    do: {:ok, :already_resolved}

  defp decode_release_reply(["IA04_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_release_reply(["IA04_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_release_reply(_reply), do: {:error, :unavailable}

  defp decode_shared_acquire_reply(["IA04_SHARED_ACQUIRED", _digest, _count]),
    do: {:ok, :acquired}

  defp decode_shared_acquire_reply(["IA04_SHARED_ALREADY_ACQUIRED", _digest, _count]),
    do: {:ok, :already_acquired}

  defp decode_shared_acquire_reply(["IA04_SHARED_BUSY"]), do: {:ok, :busy}
  defp decode_shared_acquire_reply(["IA04_SHARED_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_shared_acquire_reply(_reply), do: {:error, :unavailable}

  defp decode_shared_release_reply(["IA04_SHARED_RELEASED", _outcome, _digest, _count]),
    do: {:ok, :released}

  defp decode_shared_release_reply(["IA04_SHARED_ALREADY_RESOLVED", _outcome, _digest, _count]),
    do: {:ok, :already_resolved}

  defp decode_shared_release_reply(["IA04_SHARED_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_shared_release_reply(["IA04_SHARED_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_shared_release_reply(_reply), do: {:error, :unavailable}

  defp decode_shared_unknown_reply(["IA04_SHARED_FENCED", _digest, _count]),
    do: {:ok, :fenced}

  defp decode_shared_unknown_reply(["IA04_SHARED_ALREADY_FENCED", _digest, _count]),
    do: {:ok, :already_fenced}

  defp decode_shared_unknown_reply(["IA04_SHARED_STALE_OWNER"]), do: {:ok, :stale_owner}
  defp decode_shared_unknown_reply(["IA04_SHARED_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_shared_unknown_reply(_reply), do: {:error, :unavailable}

  defp validate_positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(_value), do: {:error, :invalid_input}

  defp validate_non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative_integer(_value), do: {:error, :invalid_input}

  defp validate_token(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256,
       do: :ok

  defp validate_token(_value), do: {:error, :invalid_input}

  defp validate_descriptor_text(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 64 do
    if Regex.match?(~r/\A[a-zA-Z0-9._:-]+\z/, value), do: :ok, else: {:error, :invalid_input}
  end

  defp validate_descriptor_text(_value), do: {:error, :invalid_input}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_input}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_input}

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, :invalid_input}
    end
  end

  defp parse_non_negative_integer(_value), do: {:error, :invalid_input}

  defp reference_context(%Reference{} = reference, opts) do
    with :ok <- validate_reference(reference),
         {:ok, options} <- reference_options(opts),
         {:ok, member} <- derive_admission_member(reference.identity_digest, options.hmac_key),
         :ok <- validate_reference_member(reference, member),
         {:ok, variant_hex} <- normalize_variant_key(reference.variant_id),
         {:ok, keys} <-
           key_set(reference.variant_id, member, reference.identity_digest, scope: options.scope) do
      {:ok, %{keys: keys, member: member, variant_hex: variant_hex}}
    end
  end

  defp validate_reference(%Reference{} = reference) do
    with true <- Reference.valid?(reference),
         :ok <- validate_digest(reference.identity_digest),
         :ok <- validate_digest(reference.request_fingerprint),
         :ok <- validate_member(reference.member),
         :ok <- validate_operation_id(reference.operation_id),
         {:ok, identities} <- reference_key_identities(reference.reservation_key),
         true <- identities.variant_id == reference.variant_id,
         {:ok, canonical_digest} <-
           Request.identity_digest_for_reservation_key(reference.reservation_key),
         true <- canonical_digest == reference.identity_digest,
         {:ok, _variant_hex} <- normalize_variant_key(reference.variant_id) do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp reference_key_identities(reservation_key) do
    case Request.classify_reservation_key(reservation_key) do
      {:ok, {_kind, identities}} -> {:ok, identities}
      _ -> {:error, :invalid_input}
    end
  end

  defp validate_reference_member(%Reference{member: expected}, expected), do: :ok
  defp validate_reference_member(_reference, _derived), do: {:error, :unavailable}

  defp reference_options(opts) do
    with :ok <- validate_keyword_options(opts, [:hmac_key, :scope]),
         {:ok, hmac_key} <- fetch_hmac_key(opts),
         {:ok, scope} <- fetch_scope(opts) do
      {:ok, %{hmac_key: hmac_key, scope: scope}}
    end
  end

  defp reference_arguments(reference, context) do
    [
      record_version(reference),
      reference.identity_digest,
      reference.request_fingerprint,
      context.member,
      context.variant_hex,
      reference.operation_id,
      Integer.to_string(reference.operation_epoch),
      reference.reservation_key
    ]
  end

  @spec decode_result(term()) :: result()
  def decode_result(["IA02_BUSY"]), do: {:ok, :busy}
  def decode_result(["IA02_MISMATCH"]), do: {:ok, :mismatch}
  def decode_result(["IA02_FROZEN"]), do: {:ok, :frozen}
  def decode_result(["IA02_UNAVAILABLE"]), do: {:error, :unavailable}

  def decode_result([tag | fields])
      when tag in ["IA02_EXISTING", "IA02_QUEUED", "IA02_ADMITTED"] do
    if length(fields) == @reply_field_count do
      case decode_admission(tag, fields) do
        {:ok, admission} -> {:ok, {status_for_tag(tag), admission}}
        {:error, :unavailable} -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  def decode_result(_reply), do: {:error, :unavailable}

  @spec decode(term()) :: result()
  def decode(reply), do: decode_result(reply)

  defp decode_status_result(["IA03_STATUS" | fields]) when length(fields) == @reply_field_count do
    case decode_admission("IA02_EXISTING", fields) do
      {:ok, admission} -> {:ok, {:status, admission}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp decode_status_result(["IA03_MISMATCH"]), do: {:ok, :mismatch}
  defp decode_status_result(["IA03_FROZEN"]), do: {:ok, :frozen}
  defp decode_status_result(["IA03_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_status_result(_reply), do: {:error, :unavailable}

  defp decode_abandon_result([tag | fields])
       when tag in ["IA03_ABANDONED", "IA03_ALREADY_ABANDONED"] and
              length(fields) == @reply_field_count do
    case decode_admission("IA02_EXISTING", fields) do
      {:ok, admission} ->
        result_tag = if tag == "IA03_ABANDONED", do: :abandoned, else: :already_abandoned
        {:ok, {result_tag, admission}}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp decode_abandon_result(["IA03_MISMATCH"]), do: {:ok, :mismatch}
  defp decode_abandon_result(["IA03_FROZEN"]), do: {:ok, :frozen}
  defp decode_abandon_result(["IA03_UNAVAILABLE"]), do: {:error, :unavailable}
  defp decode_abandon_result(_reply), do: {:error, :unavailable}

  defp status_for_tag("IA02_EXISTING"), do: :existing
  defp status_for_tag("IA02_QUEUED"), do: :queued
  defp status_for_tag("IA02_ADMITTED"), do: :admitted

  defp decode_admission(tag, [
         wire_state,
         member,
         variant_hex,
         identity_digest,
         request_fingerprint,
         operation_id,
         operation_epoch,
         sequence,
         queue_deadline_ms,
         db_deadline_ms,
         lease_deadline_ms,
         safety_margin_ms,
         owner_epoch,
         lease_token
       ]) do
    with {:ok, state} <- decode_state(wire_state),
         :ok <- validate_member(member),
         {:ok, variant_id} <- decode_variant_hex(variant_hex),
         :ok <- validate_digest(identity_digest),
         :ok <- validate_digest(request_fingerprint),
         :ok <- validate_operation_id(operation_id),
         {:ok, operation_epoch} <- decode_positive_integer(operation_epoch),
         {:ok, sequence} <- decode_non_negative_integer(sequence),
         {:ok, queue_deadline_ms} <- decode_optional_non_negative_integer(queue_deadline_ms),
         {:ok, db_deadline_ms} <- decode_optional_non_negative_integer(db_deadline_ms),
         {:ok, lease_deadline_ms} <- decode_optional_non_negative_integer(lease_deadline_ms),
         {:ok, safety_margin_ms} <- decode_optional_non_negative_integer(safety_margin_ms),
         {:ok, owner_epoch} <- decode_optional_positive_integer(owner_epoch),
         {:ok, lease_token} <- decode_optional_token(lease_token),
         :ok <- validate_decoded_status(tag, state, sequence, queue_deadline_ms, lease_token) do
      {:ok,
       %{
         status: status_for_tag(tag),
         state: state,
         member: member,
         variant_id: variant_id,
         variant_hex: variant_hex,
         identity_digest: identity_digest,
         request_fingerprint: request_fingerprint,
         operation_id: operation_id,
         operation_epoch: operation_epoch,
         sequence: sequence,
         queue_deadline_ms: queue_deadline_ms,
         db_deadline_ms: db_deadline_ms,
         lease_deadline_ms: lease_deadline_ms,
         safety_margin_ms: safety_margin_ms,
         owner_epoch: owner_epoch,
         lease_token: lease_token
       }}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp validate_decoded_status("IA02_QUEUED", :queued, sequence, queue_deadline_ms, nil)
       when sequence > 0 and is_integer(queue_deadline_ms) and queue_deadline_ms > 0,
       do: :ok

  defp validate_decoded_status("IA02_ADMITTED", :admitted, _sequence, _queue_deadline_ms, token)
       when is_binary(token),
       do: :ok

  defp validate_decoded_status("IA02_EXISTING", state, _sequence, _queue_deadline_ms, _token)
       when state in [
              :requested,
              :queued,
              :admitted,
              :reserving,
              :unknown_db_outcome,
              :recovering,
              :completed,
              :rejected,
              :expired,
              :abandoned
            ],
       do: :ok

  defp validate_decoded_status(_tag, _state, _sequence, _queue_deadline_ms, _token),
    do: {:error, :unavailable}

  defp decode_state(state) when is_binary(state) do
    case Map.fetch(@wire_states, state) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :unavailable}
    end
  end

  defp decode_state(_state), do: {:error, :unavailable}

  defp decode_variant_hex(value) when is_binary(value) do
    if Regex.match?(@variant_hex_regex, value) do
      case Base.decode16(value, case: :lower) do
        {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
        :error -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp decode_variant_hex(_value), do: {:error, :unavailable}

  defp decode_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :unavailable}
    end
  end

  defp decode_positive_integer(_value), do: {:error, :unavailable}

  defp decode_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, :unavailable}
    end
  end

  defp decode_non_negative_integer(_value), do: {:error, :unavailable}

  defp decode_optional_non_negative_integer(""), do: {:ok, nil}
  defp decode_optional_non_negative_integer(value), do: decode_non_negative_integer(value)

  defp decode_optional_positive_integer(""), do: {:ok, nil}
  defp decode_optional_positive_integer(value), do: decode_positive_integer(value)

  defp decode_optional_token(""), do: {:ok, nil}

  defp decode_optional_token(value) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp decode_optional_token(_value), do: {:error, :unavailable}

  defp validate_request(%Request{} = request) do
    case Request.validate(request) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  defp enqueue_options(opts) do
    with :ok <- validate_keyword_options(opts, @allowed_enqueue_options),
         {:ok, hmac_key} <- fetch_hmac_key(opts),
         {:ok, scope} <- fetch_scope(opts),
         {:ok, b_total} <- fetch_positive_option(opts, :b_total),
         {:ok, q_variant_max} <- fetch_non_negative_option(opts, :q_variant_max),
         {:ok, q_global_max} <- fetch_non_negative_option(opts, :q_global_max),
         {:ok, queue_window_ms} <- fetch_positive_option(opts, :queue_window_ms),
         {:ok, db_window_ms} <- fetch_positive_option(opts, :db_window_ms),
         {:ok, lease_window_ms} <- fetch_positive_option(opts, :lease_window_ms),
         {:ok, safety_margin_ms} <- fetch_non_negative_option(opts, :safety_margin_ms),
         {:ok, cleanup_limit} <- fetch_positive_option(opts, :cleanup_limit) do
      # Retention is additive: evidence outlives the longest semantic window.
      evidence_window_ms = max(queue_window_ms, lease_window_ms + safety_margin_ms)

      with {:ok, metadata_retention_ms} <-
             fetch_option_or_default(opts, :metadata_retention_ms, evidence_window_ms),
           :ok <- validate_deadline_options(lease_window_ms, db_window_ms, safety_margin_ms),
           :ok <- validate_metadata_retention(metadata_retention_ms) do
        # metadata_retention_ms is also the finite terminal replay window.
        initial_evidence_ttl_ms = evidence_window_ms + metadata_retention_ms

        {:ok,
         %{
           hmac_key: hmac_key,
           scope: scope,
           b_total: b_total,
           q_variant_max: q_variant_max,
           q_global_max: q_global_max,
           queue_window_ms: queue_window_ms,
           db_window_ms: db_window_ms,
           lease_window_ms: lease_window_ms,
           safety_margin_ms: safety_margin_ms,
           cleanup_limit: cleanup_limit,
           metadata_ttl_seconds: ceil_seconds(initial_evidence_ttl_ms),
           terminal_retention_ms: metadata_retention_ms
         }}
      end
    else
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  end

  defp promotion_options(opts) do
    with :ok <- validate_keyword_options(opts, @allowed_promotion_options),
         {:ok, hmac_key} <- fetch_hmac_key(opts),
         {:ok, scope} <- fetch_scope(opts),
         {:ok, b_total} <- fetch_positive_option(opts, :b_total),
         {:ok, cleanup_limit} <- fetch_positive_option(opts, :cleanup_limit) do
      {:ok, %{hmac_key: hmac_key, scope: scope, b_total: b_total, cleanup_limit: cleanup_limit}}
    else
      {:error, :invalid_input} -> {:error, :invalid_input}
    end
  end

  defp enqueue_arguments(request, member, operation_id, lease_token, options) do
    [
      record_version(request),
      request.identity_digest,
      request.request_fingerprint,
      member,
      keys_variant_hex(request),
      operation_id,
      lease_token,
      Integer.to_string(options.b_total),
      Integer.to_string(options.q_variant_max),
      Integer.to_string(options.q_global_max),
      Integer.to_string(options.queue_window_ms),
      Integer.to_string(options.db_window_ms),
      Integer.to_string(options.lease_window_ms),
      Integer.to_string(options.safety_margin_ms),
      Integer.to_string(options.metadata_ttl_seconds),
      Integer.to_string(options.terminal_retention_ms),
      request.reservation_key
    ]
  end

  defp promotion_arguments(request, member, lease_token, options) do
    [
      record_version(request),
      request.identity_digest,
      request.request_fingerprint,
      member,
      lease_token,
      Integer.to_string(options.b_total),
      request.reservation_key
    ]
  end

  defp record_version(%Request{} = request) do
    case Request.classify_reservation_key(request.reservation_key) do
      {:ok, {:renewal_generation, _identities}} -> @renewal_record_version
      _ -> @record_version
    end
  end

  defp record_version(%Reference{} = reference) do
    case Request.classify_reservation_key(reference.reservation_key) do
      {:ok, {:renewal_generation, _identities}} -> @renewal_record_version
      _ -> @record_version
    end
  end

  # Discovery is bounded and read-only; @expire_script revalidates every
  # candidate's state, membership, indexes, and deadline before mutating it.
  defp cleanup_expired(keys, scope, cleanup_limit) do
    with {:ok, now_ms} <- redis_server_time(),
         {:ok, members} <-
           expired_members(keys.global_queue_expiry, now_ms, cleanup_limit) do
      cleanup_members(keys, scope, members)
    end
  end

  defp cleanup_members(keys, scope, members) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      case cleanup_member(keys, scope, member) do
        :ok -> {:cont, :ok}
        {:error, :unavailable} = error -> {:halt, error}
      end
    end)
  end

  defp redis_server_time do
    case redis_command(["TIME"]) do
      {:ok, [seconds, microseconds]} ->
        parse_server_time(seconds, microseconds)

      _ ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp parse_server_time(seconds, microseconds) do
    case {Integer.parse(seconds), Integer.parse(microseconds)} do
      {{seconds, ""}, {microseconds, ""}} ->
        cond do
          seconds < 0 ->
            {:error, :unavailable}

          microseconds < 0 ->
            {:error, :unavailable}

          microseconds >= 1_000_000 ->
            {:error, :unavailable}

          true ->
            {:ok, seconds * 1_000 + div(microseconds, 1_000)}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp expired_members(key, now_ms, cleanup_limit) do
    command = [
      "ZRANGEBYSCORE",
      key,
      "-inf",
      Integer.to_string(now_ms),
      "LIMIT",
      "0",
      Integer.to_string(cleanup_limit)
    ]

    case redis_command(command) do
      {:ok, members} when is_list(members) ->
        if length(members) <= cleanup_limit and Enum.all?(members, &valid_member?/1) do
          {:ok, members}
        else
          {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp cleanup_member(keys, scope, member) do
    with :ok <- validate_member(member),
         {:ok, metadata} <- cleanup_metadata(request_meta_key(keys, member)),
         {:ok, variant_id} <- decode_variant_hex(metadata.variant_hex),
         {:ok, candidate_keys} <-
           key_set(variant_id, member, metadata.identity_digest, scope: scope),
         {:ok, reply} <-
           eval(
             @expire_script,
             expiry_script_keys(candidate_keys),
             [@record_version, member]
           ) do
      decode_expiry_reply(reply)
    end
  end

  defp cleanup_metadata(key) do
    case redis_command([
           "HMGET",
           key,
           "state",
           "identity_digest",
           "variant_hex",
           "member"
         ]) do
      {:ok, [state, identity_digest, variant_hex, member]} ->
        cleanup_metadata_values(state, identity_digest, variant_hex, member)

      _ ->
        {:error, :unavailable}
    end
  end

  defp cleanup_metadata_values(state, identity_digest, variant_hex, member)
       when is_binary(state) and is_binary(identity_digest) and is_binary(variant_hex) and
              is_binary(member) do
    with :ok <- validate_member(member),
         :ok <- validate_digest(identity_digest),
         :ok <- validate_variant_hex(variant_hex),
         {:ok, _decoded_state} <- Map.fetch(@wire_states, state) do
      {:ok, %{state: state, identity_digest: identity_digest, variant_hex: variant_hex}}
    else
      :error -> {:error, :unavailable}
      _ -> {:error, :unavailable}
    end
  end

  defp cleanup_metadata_values(_state, _identity_digest, _variant_hex, _member),
    do: {:error, :unavailable}

  defp validate_variant_hex(value) when is_binary(value) do
    if Regex.match?(@variant_hex_regex, value), do: :ok, else: {:error, :unavailable}
  end

  defp valid_member?(value), do: validate_member(value) == :ok

  defp decode_expiry_reply(["IA02_EXPIRED"]), do: :ok
  defp decode_expiry_reply(["IA02_ALREADY_HANDLED"]), do: :ok
  defp decode_expiry_reply(["IA02_NOT_EXPIRED"]), do: :ok
  defp decode_expiry_reply(_reply), do: {:error, :unavailable}

  defp request_meta_key(keys, member) do
    "#{keys.namespace}:#{keys.hash_tag}:request:#{member}:meta"
  end

  defp expiry_script_keys(keys) do
    [
      keys.variant_queue_order,
      keys.global_queue_dispatch,
      keys.global_queue_expiry,
      keys.variant_active,
      keys.global_active_expiry,
      keys.request_meta,
      keys.reservation_fence
    ]
  end

  defp keys_variant_hex(%Request{variant_id: variant_id}) do
    {:ok, variant_hex} = normalize_variant_key(variant_id)
    variant_hex
  end

  defp eval(script, keys, args) do
    command = ["EVAL", script, Integer.to_string(length(keys))] ++ keys ++ args

    case redis_command(command) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp redis_command(command) do
    case Redix.command(RedixClient.connection_name(), command) do
      {:ok, reply} -> {:ok, reply}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp script_keys(keys) do
    [
      keys.global_sequence,
      keys.variant_queue_order,
      keys.global_queue_dispatch,
      keys.global_queue_expiry,
      keys.variant_active,
      keys.global_active_expiry,
      keys.request_meta,
      keys.reservation_fence
    ]
  end

  defp fetch_hmac_key(opts) do
    case Keyword.fetch(opts, :hmac_key) do
      {:ok, hmac_key} ->
        case validate_hmac_key(hmac_key) do
          :ok -> {:ok, hmac_key}
          {:error, :invalid_input} -> {:error, :invalid_input}
        end

      :error ->
        {:error, :unavailable}
    end
  end

  defp fetch_scope(opts) do
    scope = Keyword.get(opts, :scope, @default_scope)

    if is_binary(scope) and Regex.match?(@scope_regex, scope) do
      {:ok, scope}
    else
      {:error, :invalid_input}
    end
  end

  defp fetch_version(opts) do
    version = Keyword.get(opts, :version, @namespace_version)

    if is_binary(version) and Regex.match?(@version_regex, version) do
      {:ok, version}
    else
      {:error, :invalid_input}
    end
  end

  defp fetch_key_prefix do
    prefix =
      Application.get_env(:store, :rate_limit, [])
      |> Keyword.get(:redis_key_prefix, @key_prefix_fallback)

    if is_binary(prefix) and byte_size(prefix) > 0 do
      {:ok, prefix}
    else
      {:error, :invalid_input}
    end
  end

  defp fetch_positive_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_input}
    end
  end

  defp fetch_non_negative_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_input}
    end
  end

  defp fetch_option_or_default(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_input}
    end
  end

  defp validate_deadline_options(lease_window_ms, db_window_ms, safety_margin_ms) do
    if lease_window_ms >= db_window_ms + safety_margin_ms do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp validate_metadata_retention(metadata_retention_ms)
       when is_integer(metadata_retention_ms) and metadata_retention_ms > 0,
       do: :ok

  defp ceil_seconds(milliseconds), do: div(milliseconds + 999, 1000)

  defp validate_keyword_options(opts, allowed) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp validate_hmac_key(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_hmac_key(_value), do: {:error, :invalid_input}

  defp validate_digest(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: :ok, else: {:error, :invalid_input}
  end

  defp validate_digest(_value), do: {:error, :invalid_input}

  defp validate_member(value) when is_binary(value) do
    if Regex.match?(@member_regex, value), do: :ok, else: {:error, :invalid_input}
  end

  defp validate_member(_value), do: {:error, :invalid_input}

  defp validate_version(value) when is_binary(value) do
    if Regex.match?(@version_regex, value), do: :ok, else: {:error, :invalid_input}
  end

  defp validate_version(_value), do: {:error, :invalid_input}

  defp validate_operation_id(value) when is_binary(value) do
    if UUIDv7.valid?(value), do: :ok, else: {:error, :unavailable}
  end

  defp validate_operation_id(_value), do: {:error, :unavailable}

  defp generate_lease_token do
    :crypto.strong_rand_bytes(32)
    |> Base.encode16(case: :lower)
  end
end
