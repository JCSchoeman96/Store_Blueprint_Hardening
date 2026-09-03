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

  alias Store.Orders.InventoryAdmission.Request
  alias Store.Support.ID.UUIDv7
  alias Store.Support.RateLimit.RedixClient

  @namespace_version "v1"
  @record_version "ia02:v1"
  @default_scope "default"
  @key_prefix_fallback "store"
  @k_v 1

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
      "metadata_ttl_seconds"
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
      "operation_epoch"
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

  local function validate_existing(meta, fence, schema, identity, variant_hex, member)
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
        "safety_margin_ms"
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
        and active_score ~= false
        and tonumber(active_score) == tonumber(meta[15])
    end

    return true
  end

  local function expire_queued(meta)
    redis.call("ZREM", KEYS[2], meta[5])
    redis.call("ZREM", KEYS[3], meta[5])
    redis.call("ZREM", KEYS[4], meta[5])
    redis.call("HSET", KEYS[7], "state", "EXPIRED")
    redis.call("HSET", KEYS[8], "state", "EXPIRED")
    meta[2] = "EXPIRED"
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
      "safety_margin_ms"
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
    or b_total < 1
    or q_variant_max < 0
    or q_global_max < 0
    or queue_window_ms < 1
    or db_window_ms < 1
    or lease_window_ms < db_window_ms + safety_margin_ms
    or metadata_ttl_seconds < 1 then
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
  elseif not validate_existing(metadata, fence, schema, identity, variant_hex, member) then
    return unavailable()
  else
    if metadata_state == "QUEUED" then
      local queue_deadline_ms = tonumber(metadata[10])
      now_ms = server_now_ms()

      if queue_deadline_ms == nil or now_ms == nil then
        return unavailable()
      end

      if now_ms >= queue_deadline_ms then
        if not existing_indexes_valid(metadata) then
          return unavailable()
        end

        expire_queued(metadata)
        metadata_state = "EXPIRED"
      end
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
    if active_values[1] ~= schema
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
      "operation_epoch", operation_epoch
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
      "sequence", "0",
      "queue_deadline_ms", "",
      "db_window_ms", db_window_ms,
      "lease_window_ms", lease_window_ms,
      "safety_margin_ms", safety_margin_ms,
      "db_deadline_ms", db_deadline_ms,
      "lease_deadline_ms", lease_deadline_ms,
      "lease_token", lease_token,
      "owner_epoch", operation_epoch,
      "metadata_ttl_seconds", metadata_ttl_seconds
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
    "operation_epoch", operation_epoch
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
    "sequence", sequence_reply,
    "queue_deadline_ms", queue_deadline_ms,
    "db_window_ms", db_window_ms,
    "lease_window_ms", lease_window_ms,
    "safety_margin_ms", safety_margin_ms,
    "db_deadline_ms", "",
    "lease_deadline_ms", "",
    "lease_token", "",
    "owner_epoch", "",
    "metadata_ttl_seconds", metadata_ttl_seconds
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
    "queue_deadline_ms"
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
    "operation_epoch"
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
    or metadata[1] ~= schema
    or fence[1] ~= schema
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

  if sequence == nil
    or sequence < 1
    or queue_deadline_ms == nil
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

  local schema = ARGV[1]
  local identity = ARGV[2]
  local fingerprint = ARGV[3]
  local member = ARGV[4]
  local lease_token = ARGV[5]
  local b_total = tonumber(ARGV[6])

  if schema == nil
    or identity == nil
    or fingerprint == nil
    or member == nil
    or lease_token == nil
    or b_total == nil
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
    "metadata_ttl_seconds"
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
    "operation_epoch"
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
    or metadata[4] == false
    or metadata[7] == false
    or metadata[8] == false
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
  if now_ms == nil or queue_deadline_ms == nil then
    return unavailable()
  end

  if now_ms >= queue_deadline_ms then
    redis.call("ZREM", KEYS[2], member)
    redis.call("ZREM", KEYS[3], member)
    redis.call("ZREM", KEYS[4], member)
    redis.call("HSET", KEYS[7], "state", "EXPIRED")
    redis.call("HSET", KEYS[8], "state", "EXPIRED")
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
      or active_values[1] ~= schema
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

  if now_ms == nil
    or queue_deadline_ms == nil
    or db_window_ms == nil
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
    "operation_epoch", metadata[8]
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

  @type status :: :existing | :queued | :admitted | :busy | :mismatch | :frozen
  @type failure :: :unavailable | :invalid_input

  @type admission :: %{
          status: :existing | :queued | :admitted,
          state: InventoryAdmission.state(),
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
  def normalize_variant_key(value) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, Base.encode16(raw16, case: :lower)}
      :error -> {:error, :invalid_input}
    end
  end

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
         reservation_fence: "#{base}:reservation:#{identity_digest}:mutation_fence"
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
    with true <- Regex.match?(@variant_hex_regex, value),
         {:ok, raw16} <- Base.decode16(value, case: :lower) do
      {:ok, UUIDv7.encode!(raw16)}
    else
      _ -> {:error, :unavailable}
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
      metadata_default = max(queue_window_ms, lease_window_ms + safety_margin_ms)

      with {:ok, metadata_retention_ms} <-
             fetch_option_or_default(opts, :metadata_retention_ms, metadata_default),
           :ok <- validate_deadline_options(lease_window_ms, db_window_ms, safety_margin_ms),
           :ok <-
             validate_metadata_retention(metadata_retention_ms, lease_window_ms, safety_margin_ms) do
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
           metadata_ttl_seconds: ceil_seconds(metadata_retention_ms)
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
      @record_version,
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
      Integer.to_string(options.metadata_ttl_seconds)
    ]
  end

  defp promotion_arguments(request, member, lease_token, options) do
    [
      @record_version,
      request.identity_digest,
      request.request_fingerprint,
      member,
      lease_token,
      Integer.to_string(options.b_total)
    ]
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
      {:ok, [seconds, microseconds]} when is_binary(seconds) and is_binary(microseconds) ->
        with {seconds, ""} <- Integer.parse(seconds),
             {microseconds, ""} <- Integer.parse(microseconds),
             true <- seconds >= 0 and microseconds >= 0 and microseconds < 1_000_000 do
          {:ok, seconds * 1_000 + div(microseconds, 1_000)}
        else
          _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
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
      {:ok, [state, identity_digest, variant_hex, member]}
      when is_binary(state) and is_binary(identity_digest) and is_binary(variant_hex) and
             is_binary(member) ->
        with :ok <- validate_member(member),
             :ok <- validate_digest(identity_digest),
             :ok <- validate_variant_hex(variant_hex),
             true <- Map.has_key?(@wire_states, state) do
          {:ok, %{state: state, identity_digest: identity_digest, variant_hex: variant_hex}}
        else
          _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp validate_variant_hex(value) when is_binary(value) do
    if Regex.match?(@variant_hex_regex, value), do: :ok, else: {:error, :unavailable}
  end

  defp validate_variant_hex(_value), do: {:error, :unavailable}

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

      _unexpected ->
        {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp redis_command(command) do
    case Redix.command(RedixClient.connection_name(), command) do
      {:ok, reply} -> {:ok, reply}
      {:error, _reason} -> {:error, :unavailable}
      _unexpected -> {:error, :unavailable}
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

  defp validate_metadata_retention(metadata_retention_ms, lease_window_ms, safety_margin_ms) do
    if metadata_retention_ms >= lease_window_ms + safety_margin_ms do
      :ok
    else
      {:error, :invalid_input}
    end
  end

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
