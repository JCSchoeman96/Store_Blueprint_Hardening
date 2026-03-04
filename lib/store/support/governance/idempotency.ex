defmodule Store.Support.Governance.Idempotency do
  @moduledoc """
  Deterministic idempotency helpers for payment/provider event and refund flows.
  """

  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.ID.UUIDv7

  @spec provider_event_key(String.t() | atom(), String.t()) :: String.t()
  def provider_event_key(provider, provider_event_id)
      when (is_binary(provider) or is_atom(provider)) and is_binary(provider_event_id) do
    "#{normalize_provider(provider)}:#{provider_event_id}"
  end

  @spec cart_fingerprint([map()], String.t(), DateTime.t() | String.t(), String.t(), map()) ::
          String.t()
  def cart_fingerprint(line_items, currency, as_of, pricing_contract_version, tax_shipping_inputs)
      when is_list(line_items) and is_binary(currency) and is_binary(pricing_contract_version) and
             is_map(tax_shipping_inputs) do
    normalized_lines =
      line_items
      |> normalize_checkout_lines()
      |> Enum.sort_by(fn {variant_raw16, plan_raw16, _quantity} ->
        {variant_raw16, plan_raw16 || <<>>}
      end)

    payload =
      {
        normalized_lines,
        String.upcase(currency),
        normalize_as_of(as_of),
        pricing_contract_version,
        canonical_term(tax_shipping_inputs)
      }

    payload
    |> :erlang.term_to_binary()
    |> hash_base32()
  end

  @spec checkout_key(String.t() | nil, String.t()) :: String.t()
  def checkout_key(user_id, cart_fingerprint)
      when (is_binary(user_id) or is_nil(user_id)) and is_binary(cart_fingerprint) do
    user_scope =
      case user_id do
        value when is_binary(value) -> value
        _ -> "guest"
      end

    "ck:" <> hash_base32("user:#{user_scope}|cart:#{cart_fingerprint}")
  end

  @spec payment_intent_key(String.t(), integer(), String.t(), String.t() | atom()) :: String.t()
  def payment_intent_key(order_id, amount_minor, currency, provider)
      when is_binary(order_id) and is_integer(amount_minor) and is_binary(currency) and
             (is_binary(provider) or is_atom(provider)) do
    {"order", order_id, "amount", amount_minor, "currency", String.upcase(currency), "provider",
     normalize_provider(provider)}
    |> :erlang.term_to_binary()
    |> hash_base32()
    |> then(&("pi:" <> &1))
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

  @spec refund_request_fingerprint(
          String.t(),
          integer(),
          String.t(),
          String.t(),
          atom() | String.t()
        ) :: String.t()
  def refund_request_fingerprint(
        scope_hash,
        amount_minor,
        currency,
        reason,
        scope_kind \\ :partial_refund
      )

  def refund_request_fingerprint(scope_hash, amount_minor, currency, reason, scope_kind)
      when is_binary(scope_hash) and is_integer(amount_minor) and is_binary(currency) and
             is_binary(reason) do
    hash_sha256(
      "#{scope_hash}|#{amount_minor}|#{currency}|#{reason}|#{normalize_scope_kind(scope_kind)}"
    )
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

  defp normalize_checkout_lines(line_items) do
    line_items
    |> Enum.reduce(%{}, fn line_item, acc ->
      {variant_id, subscription_plan_id} = checkout_line_ids(line_item)
      quantity = checkout_line_quantity(line_item)
      variant_raw16 = UUIDv7.decode!(variant_id)
      subscription_plan_raw16 = decode_optional_uuid(subscription_plan_id)
      composite_key = {variant_raw16, subscription_plan_raw16}

      Map.update(acc, composite_key, quantity, &(&1 + quantity))
    end)
    |> Enum.map(fn {{variant_raw16, plan_raw16}, quantity} ->
      {variant_raw16, plan_raw16, quantity}
    end)
  end

  defp checkout_line_ids(line_item) when is_map(line_item) do
    variant_id =
      Map.get(line_item, :variant_id) ||
        Map.get(line_item, "variant_id") ||
        Map.get(line_item, :sku_id) ||
        Map.get(line_item, "sku_id") ||
        raise ArgumentError, "checkout line item requires variant_id or sku_id"

    subscription_plan_id =
      Map.get(line_item, :subscription_plan_id) ||
        Map.get(line_item, "subscription_plan_id")

    {variant_id, subscription_plan_id}
  end

  defp checkout_line_ids(_line_item),
    do: raise(ArgumentError, "checkout line item must be a map")

  defp checkout_line_quantity(line_item) when is_map(line_item) do
    quantity = Map.get(line_item, :quantity) || Map.get(line_item, "quantity") || 0

    if is_integer(quantity) and quantity > 0 do
      quantity
    else
      raise ArgumentError, "checkout line item quantity must be a positive integer"
    end
  end

  defp checkout_line_quantity(_line_item),
    do: raise(ArgumentError, "checkout line item quantity must be a positive integer")

  defp normalize_as_of(%DateTime{} = as_of), do: DateTime.to_iso8601(as_of)
  defp normalize_as_of(as_of) when is_binary(as_of), do: as_of
  defp normalize_as_of(_as_of), do: raise(ArgumentError, "as_of must be DateTime or ISO8601")

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {normalize_term_key(key), canonical_term(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp normalize_term_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_term_key(key) when is_binary(key), do: key
  defp normalize_term_key(key), do: inspect(key)

  defp hash_base32(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp hash_sha256(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp normalize_scope_kind(scope_kind) when is_atom(scope_kind), do: Atom.to_string(scope_kind)
  defp normalize_scope_kind(scope_kind) when is_binary(scope_kind), do: scope_kind
  defp normalize_scope_kind(_scope_kind), do: "partial_refund"

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp decode_optional_uuid(nil), do: nil
  defp decode_optional_uuid(""), do: nil

  defp decode_optional_uuid(id) when is_binary(id) do
    UUIDv7.decode!(id)
  end
end
