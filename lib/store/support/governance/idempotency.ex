defmodule Store.Support.Governance.Idempotency do
  @moduledoc """
  Deterministic idempotency helpers for payment/provider event and refund flows.
  """

  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.ID.UUIDv7

  @spec provider_event_key(String.t(), String.t()) :: String.t()
  def provider_event_key(provider, provider_event_id)
      when is_binary(provider) and is_binary(provider_event_id) do
    "#{provider}:#{provider_event_id}"
  end

  @spec refund_scope_hash([String.t() | binary()]) :: String.t()
  def refund_scope_hash(line_item_ids) when is_list(line_item_ids) do
    case line_item_ids do
      [] ->
        hash_sha256("order-level")

      ids ->
        ids
        |> BinaryUuidSort.sort_raw16()
        |> Enum.map_join(",", &UUIDv7.encode!/1)
        |> hash_sha256()
    end
  end

  @spec refund_idempotency_key(String.t(), integer(), String.t(), String.t()) :: String.t()
  def refund_idempotency_key(order_id, amount_minor, reason, scope_hash)
      when is_binary(order_id) and is_integer(amount_minor) and is_binary(reason) and
             is_binary(scope_hash) do
    "refund:order:#{order_id}:amount:#{amount_minor}:reason:#{reason}:scope:#{scope_hash}"
  end

  @spec refund_request_fingerprint(String.t(), integer(), String.t(), String.t()) :: String.t()
  def refund_request_fingerprint(scope_hash, amount_minor, currency, reason)
      when is_binary(scope_hash) and is_integer(amount_minor) and is_binary(currency) and
             is_binary(reason) do
    hash_sha256("#{scope_hash}|#{amount_minor}|#{currency}|#{reason}")
  end

  @spec payload_hash(term()) :: String.t() | nil
  def payload_hash(payload)

  def payload_hash(nil), do: nil

  def payload_hash(payload) when is_binary(payload) do
    hash_sha256(payload)
  end

  def payload_hash(payload) when is_map(payload) or is_list(payload) do
    payload
    |> Jason.encode!()
    |> hash_sha256()
  end

  def payload_hash(payload), do: payload |> inspect() |> hash_sha256()

  defp hash_sha256(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
