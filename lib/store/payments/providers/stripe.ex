defmodule Store.Payments.Providers.Stripe do
  @moduledoc """
  Stripe provider boundary adapter.

  This adapter verifies webhook signatures and normalizes Stripe event payloads.
  Intent creation returns deterministic redirect metadata for checkout orchestration.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Support.Errors.Error

  @default_tolerance_seconds 300

  @impl true
  def capabilities do
    %{
      supports_one_time_checkout?: true,
      supports_refunds?: true,
      supports_partial_refunds?: true,
      supports_tokenization?: true,
      supports_merchant_initiated_charges?: true,
      supports_provider_managed_subscriptions?: true,
      webhook_verification_mode: :offline_hmac,
      supports_webhooks?: true
    }
  end

  @impl true
  def create_intent(attrs, _opts) when is_map(attrs) do
    with {:ok, order_ref} <- fetch_required_binary(attrs, :order_ref),
         {:ok, amount_minor} <- fetch_required_integer(attrs, :amount_minor),
         {:ok, currency} <- fetch_required_binary(attrs, :currency),
         {:ok, payment_intent_key} <- fetch_required_binary(attrs, :payment_intent_key),
         {:ok, idempotency_key} <- fetch_required_binary(attrs, :idempotency_key),
         {:ok, return_url} <- fetch_required_binary(attrs, :return_url),
         {:ok, cancel_url} <- fetch_required_binary(attrs, :cancel_url) do
      provider_session_id = "cs_store_#{short_hash(payment_intent_key)}"
      provider_payment_id = "pi_store_#{short_hash("#{payment_intent_key}:#{idempotency_key}")}"

      checkout_base_url =
        Application.get_env(:store, :payments, [])
        |> Keyword.get(:stripe, [])
        |> Keyword.get(:checkout_base_url, "https://checkout.stripe.example")

      checkout_url =
        "#{String.trim_trailing(checkout_base_url, "/")}/" <>
          "#{provider_session_id}?order_ref=#{order_ref}&amount=#{amount_minor}&currency=#{String.downcase(currency)}" <>
          "&payment_intent_id=#{provider_payment_id}" <>
          "&idempotency_key=#{URI.encode(idempotency_key)}" <>
          "&return_url=#{URI.encode(return_url)}&cancel_url=#{URI.encode(cancel_url)}"

      {:ok,
       %{
         provider_session_id: provider_session_id,
         provider_payment_id: provider_payment_id,
         provider_checkout_url: checkout_url,
         provider_client_secret: nil
       }}
    end
  end

  @impl true
  def verify_webhook(headers, raw_body, opts) when is_map(headers) and is_binary(raw_body) do
    with {:ok, signature_header} <- fetch_signature_header(headers),
         {:ok, secret} <- fetch_webhook_secret(opts),
         {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- validate_timestamp(timestamp, opts),
         :ok <- validate_signature(secret, timestamp, raw_body, signatures) do
      decode_payload(raw_body)
    end
  end

  @impl true
  def normalize_webhook(payload) when is_map(payload) do
    with {:ok, provider_event_id} <- extract_provider_event_id(payload),
         {:ok, event_type} <- extract_event_type(payload),
         {:ok, provider_session_id} <- extract_provider_session_id(payload, event_type),
         {:ok, provider_payment_id} <- extract_provider_payment_id(payload, event_type),
         {:ok, amount_minor} <- extract_amount_minor(payload),
         {:ok, currency} <- extract_currency(payload) do
      {:ok,
       %CanonicalReceipt{
         provider: "stripe",
         provider_event_id: provider_event_id,
         provider_session_id: provider_session_id,
         provider_payment_id: provider_payment_id,
         provider_idempotency_key: extract_idempotency_key(payload),
         status: normalize_status(event_type),
         amount_minor: amount_minor,
         currency: currency,
         order_ref: extract_order_ref(payload),
         occurred_at: extract_occurred_at(payload),
         event_type: event_type,
         raw_payload: payload
       }}
    end
  end

  def normalize_webhook(_payload) do
    {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "stripe webhook payload must be a map")}
  end

  defp fetch_signature_header(headers) do
    case header_value(headers, "stripe-signature") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, Error.new("PAYMENT_SIGNATURE_MISSING", "stripe-signature header is required")}
    end
  end

  defp fetch_webhook_secret(opts) do
    configured_secret =
      opts
      |> Keyword.get(:webhook_secret)
      |> case do
        secret when is_binary(secret) and secret != "" ->
          secret

        _ ->
          Application.get_env(:store, :payments, [])
          |> Keyword.get(:stripe, [])
          |> Keyword.get(:webhook_secret)
      end

    case configured_secret do
      secret when is_binary(secret) and secret != "" ->
        {:ok, secret}

      _ ->
        {:error,
         Error.new("PAYMENT_SIGNATURE_INVALID", "stripe webhook secret is not configured")}
    end
  end

  defp parse_signature_header(signature_header) do
    parsed =
      signature_header
      |> String.split(",", trim: true)
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> Map.update(acc, key, [value], &[value | &1])
          _ -> acc
        end
      end)

    case {Map.get(parsed, "t"), Map.get(parsed, "v1")} do
      {[timestamp | _], signatures} when is_list(signatures) and signatures != [] ->
        case Integer.parse(timestamp) do
          {parsed_timestamp, ""} ->
            {:ok, parsed_timestamp, signatures}

          _ ->
            {:error, Error.new("PAYMENT_SIGNATURE_INVALID", "invalid stripe-signature timestamp")}
        end

      _ ->
        {:error, Error.new("PAYMENT_SIGNATURE_INVALID", "stripe-signature must include t and v1")}
    end
  end

  defp validate_timestamp(timestamp, opts) when is_integer(timestamp) do
    tolerance_seconds = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)
    now = DateTime.utc_now() |> DateTime.to_unix()

    if abs(now - timestamp) <= tolerance_seconds do
      :ok
    else
      {:error,
       Error.new(
         "PAYMENT_SIGNATURE_INVALID",
         "stripe webhook signature timestamp outside tolerance"
       )}
    end
  end

  defp validate_signature(secret, timestamp, raw_body, signatures) do
    signed_payload = "#{timestamp}.#{raw_body}"

    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, signed_payload)
      |> Base.encode16(case: :lower)

    if Enum.any?(signatures, &secure_compare(&1, expected_signature)) do
      :ok
    else
      {:error, Error.new("PAYMENT_SIGNATURE_INVALID", "stripe webhook signature mismatch")}
    end
  end

  defp decode_payload(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "invalid stripe webhook JSON")}
    end
  end

  defp extract_provider_event_id(payload) do
    case Map.get(payload, "id") || Map.get(payload, "provider_event_id") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing provider event id")}
    end
  end

  defp extract_event_type(payload) do
    case Map.get(payload, "type") || Map.get(payload, "event_type") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing event type")}
    end
  end

  defp extract_provider_session_id(payload, event_type) do
    payload
    |> provider_session_id_candidate(event_type)
    |> normalize_required_session_id()
  end

  defp provider_session_id_candidate(payload, <<"checkout.session.", _::binary>>) do
    object = payload_object(payload)
    object["id"] || Map.get(payload, "provider_session_id")
  end

  defp provider_session_id_candidate(payload, _event_type) do
    object = payload_object(payload)
    metadata = object["metadata"] || %{}

    object["checkout_session_id"] ||
      metadata["checkout_session_id"] ||
      Map.get(payload, "provider_session_id") ||
      object["id"]
  end

  defp normalize_required_session_id(value) when is_binary(value) and value != "" do
    {:ok, value}
  end

  defp normalize_required_session_id(_value) do
    {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing stripe checkout session id")}
  end

  defp extract_provider_payment_id(payload, event_type) do
    object = payload_object(payload)

    candidate =
      case event_type do
        <<"checkout.session.", _::binary>> ->
          object["payment_intent"] || Map.get(payload, "payment_intent_id")

        _ ->
          object["id"] || Map.get(payload, "payment_intent_id")
      end

    case candidate do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:ok, nil}
    end
  end

  defp extract_amount_minor(payload) do
    object = payload_object(payload)

    case object["amount_total"] || object["amount_received"] || object["amount"] ||
           Map.get(payload, "amount_minor") do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing stripe amount")}
    end
  end

  defp extract_currency(payload) do
    object = payload_object(payload)

    case object["currency"] || Map.get(payload, "currency") do
      value when is_binary(value) and value != "" ->
        {:ok, value |> String.trim() |> String.upcase()}

      _ ->
        {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing stripe currency")}
    end
  end

  defp extract_idempotency_key(payload) do
    object = payload_object(payload)
    object["idempotency_key"] || get_in(payload, ["request", "idempotency_key"])
  end

  defp extract_order_ref(payload) do
    metadata = payload_object(payload)["metadata"] || %{}
    metadata["order_ref"] || metadata["checkout_key"]
  end

  defp extract_occurred_at(payload) do
    case Map.get(payload, "created") do
      created when is_integer(created) and created > 0 ->
        DateTime.from_unix!(created)

      _ ->
        DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp normalize_status(event_type)
       when event_type in [
              "checkout.session.completed",
              "payment_intent.succeeded",
              "charge.succeeded"
            ],
       do: :succeeded

  defp normalize_status(event_type)
       when event_type in [
              "checkout.session.expired",
              "payment_intent.payment_failed",
              "charge.failed"
            ],
       do: :failed

  defp normalize_status(_event_type), do: :unknown

  defp payload_object(payload) when is_map(payload) do
    get_in(payload, ["data", "object"]) || Map.get(payload, "data_object") || %{}
  end

  defp header_value(headers, key) do
    case Map.get(headers, key) || Map.get(headers, String.downcase(key)) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      Plug.Crypto.secure_compare(left, right)
    else
      false
    end
  end

  defp fetch_required_binary(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
    end
  end

  defp fetch_required_integer(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
    end
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
