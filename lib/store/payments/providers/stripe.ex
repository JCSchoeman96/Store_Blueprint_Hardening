defmodule Store.Payments.Providers.Stripe do
  @moduledoc """
  Stripe provider boundary adapter.

  This adapter performs Stripe API calls, verifies webhook signatures, and
  normalizes Stripe payloads into canonical receipts.
  """

  @behaviour Store.Payments.Providers.Behaviour

  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Support.Errors.Error
  alias Store.Support.HTTP.ReqClient

  @default_api_base_url "https://api.stripe.com"
  @default_api_version "2024-06-20"
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
  def create_intent(attrs, opts) when is_map(attrs) and is_list(opts) do
    case attr(attrs, :intent_purpose) do
      :subscription_payment_method_update ->
        create_setup_intent(attrs, opts)

      _ ->
        create_checkout_intent(attrs, opts)
    end
  end

  @impl true
  def charge_off_session(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, amount_minor} <- fetch_required_integer(attrs, :amount_minor),
         {:ok, currency} <- fetch_required_binary(attrs, :currency),
         {:ok, renewal_key} <- fetch_required_binary(attrs, :renewal_key),
         {:ok, local_intent_id} <- fetch_required_binary(attrs, :local_intent_id),
         {:ok, order_id} <- fetch_required_binary(attrs, :order_id),
         {:ok, renewal_attempt_id} <- fetch_required_binary(attrs, :renewal_attempt_id),
         {:ok, subscription_id} <- fetch_required_binary(attrs, :subscription_id),
         {:ok, provider_customer_ref} <- fetch_required_binary(attrs, :provider_customer_ref),
         {:ok, provider_payment_method_ref} <-
           fetch_required_binary(attrs, :provider_payment_method_ref),
         {:ok, response} <-
           stripe_post(
             "/v1/payment_intents",
             %{
               "amount" => Integer.to_string(amount_minor),
               "confirm" => "true",
               "currency" => stripe_currency(currency),
               "customer" => provider_customer_ref,
               "description" => "Subscription renewal #{renewal_key}",
               "metadata[local_intent_id]" => local_intent_id,
               "metadata[order_id]" => order_id,
               "metadata[renewal_attempt_id]" => renewal_attempt_id,
               "metadata[renewal_key]" => renewal_key,
               "metadata[subscription_id]" => subscription_id,
               "off_session" => "true",
               "payment_method" => provider_payment_method_ref
             },
             renewal_key,
             opts
           ),
         {:ok, payment_intent} <- extract_payment_intent_response(response) do
      {:ok,
       %{
         status: normalize_charge_status(payment_intent, response),
         idempotency_key: renewal_key,
         confirm: true,
         off_session: true,
         amount_minor: amount_minor,
         currency: String.upcase(currency),
         provider_payment_id: payment_intent["id"],
         provider_customer_ref: payment_intent["customer"] || provider_customer_ref,
         provider_payment_method_ref:
           payment_intent["payment_method"] || provider_payment_method_ref,
         provider_client_secret: payment_intent["client_secret"],
         action_url: extract_action_url(%{"data" => %{"object" => payment_intent}}),
         metadata: %{
           local_intent_id: local_intent_id,
           order_id: order_id,
           renewal_attempt_id: renewal_attempt_id,
           subscription_id: subscription_id,
           renewal_key: renewal_key
         }
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
         provider_customer_ref: extract_provider_customer_ref(payload),
         provider_payment_method_ref: extract_provider_payment_method_ref(payload),
         local_payment_intent_id: extract_local_payment_intent_id(payload),
         status: normalize_status(event_type),
         amount_minor: amount_minor,
         currency: currency,
         order_ref: extract_order_ref(payload),
         action_url: extract_action_url(payload),
         client_secret: extract_client_secret(payload),
         occurred_at: extract_occurred_at(payload),
         event_type: event_type,
         raw_payload: payload
       }}
    end
  end

  def normalize_webhook(_payload) do
    {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "stripe webhook payload must be a map")}
  end

  defp create_checkout_intent(attrs, opts) do
    with {:ok, order_ref} <- fetch_required_binary(attrs, :order_ref),
         {:ok, order_id} <- fetch_required_binary(attrs, :order_id),
         {:ok, checkout_key} <- fetch_required_binary(attrs, :checkout_key),
         {:ok, local_intent_id} <- fetch_required_binary(attrs, :local_intent_id),
         {:ok, amount_minor} <- fetch_required_integer(attrs, :amount_minor),
         {:ok, currency} <- fetch_required_binary(attrs, :currency),
         {:ok, payment_intent_key} <- fetch_required_binary(attrs, :payment_intent_key),
         {:ok, idempotency_key} <- fetch_required_binary(attrs, :idempotency_key),
         {:ok, return_url} <- fetch_required_binary(attrs, :return_url),
         {:ok, cancel_url} <- fetch_required_binary(attrs, :cancel_url) do
      has_subscription_lines? = truthy_attr?(attrs, :has_subscription_lines?)
      save_for_off_session? = truthy_attr?(attrs, :save_payment_method_for_off_session?)

      checkout_mode =
        derive_checkout_mode(amount_minor, attr(attrs, :checkout_mode), has_subscription_lines?)

      metadata = %{
        "checkout_key" => checkout_key,
        "local_intent_id" => local_intent_id,
        "order_id" => order_id,
        "order_ref" => order_ref,
        "payment_intent_key" => payment_intent_key
      }

      form =
        %{
          "cancel_url" => cancel_url,
          "customer_creation" => "always",
          "metadata[checkout_key]" => metadata["checkout_key"],
          "metadata[local_intent_id]" => metadata["local_intent_id"],
          "metadata[order_id]" => metadata["order_id"],
          "metadata[order_ref]" => metadata["order_ref"],
          "metadata[payment_intent_key]" => metadata["payment_intent_key"],
          "mode" => Atom.to_string(checkout_mode),
          "payment_method_types[0]" => "card",
          "success_url" => return_url
        }
        |> maybe_put_payment_line_item(checkout_mode, amount_minor, currency, order_ref)
        |> maybe_put_payment_intent_data(checkout_mode, metadata, currency, save_for_off_session?)
        |> maybe_put_setup_intent_data(checkout_mode, metadata, currency)

      case stripe_post("/v1/checkout/sessions", form, idempotency_key, opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok,
           %{
             provider_session_id: body["id"],
             provider_payment_id: stripe_id(body["payment_intent"]),
             provider_customer_ref: body["customer"],
             provider_checkout_url: body["url"],
             provider_client_secret: nil,
             checkout_mode: checkout_mode
           }}

        {:ok, response} ->
          stripe_error(response)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp create_setup_intent(attrs, opts) do
    with {:ok, payment_intent_key} <- fetch_required_binary(attrs, :payment_intent_key),
         {:ok, local_intent_id} <- fetch_required_binary(attrs, :local_intent_id),
         {:ok, subscription_id} <- fetch_required_binary(attrs, :subscription_id),
         {:ok, provider_customer_ref} <- fetch_required_binary(attrs, :provider_customer_ref),
         {:ok, currency} <- fetch_required_binary(attrs, :currency),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           stripe_post(
             "/v1/setup_intents",
             %{
               "customer" => provider_customer_ref,
               "metadata[currency]" => String.upcase(currency),
               "metadata[local_intent_id]" => local_intent_id,
               "metadata[payment_intent_key]" => payment_intent_key,
               "metadata[subscription_id]" => subscription_id,
               "payment_method_types[0]" => "card",
               "usage" => "off_session"
             },
             payment_intent_key,
             opts
           ) do
      {:ok,
       %{
         provider_session_id: nil,
         provider_payment_id: body["id"],
         provider_customer_ref: body["customer"] || provider_customer_ref,
         provider_client_secret: body["client_secret"],
         metadata: %{
           local_intent_id: local_intent_id,
           subscription_id: subscription_id,
           currency: String.upcase(currency)
         }
       }}
    else
      {:ok, response} -> stripe_error(response)
      {:error, _reason} = error -> error
    end
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
    {:ok, provider_session_id_candidate(payload, event_type)}
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
      Map.get(payload, "provider_session_id")
  end

  defp extract_provider_payment_id(payload, event_type) do
    object = payload_object(payload)

    candidate =
      case event_type do
        <<"checkout.session.", _::binary>> ->
          stripe_id(object["payment_intent"]) || Map.get(payload, "payment_intent_id")

        _ ->
          stripe_id(object["id"]) || Map.get(payload, "payment_intent_id")
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
    event_type = Map.get(payload, "type") || Map.get(payload, "event_type")

    case object["amount_total"] || object["amount_received"] || object["amount"] ||
           Map.get(payload, "amount_minor") ||
           setup_intent_amount(event_type) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, Error.new("PAYMENT_PAYLOAD_INVALID", "missing stripe amount")}
    end
  end

  defp extract_currency(payload) do
    object = payload_object(payload)
    metadata = object["metadata"] || %{}

    case object["currency"] || metadata["currency"] || Map.get(payload, "currency") do
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

  defp extract_provider_customer_ref(payload) do
    object = payload_object(payload)
    stripe_id(object["customer"]) || Map.get(payload, "provider_customer_ref")
  end

  defp extract_provider_payment_method_ref(payload) do
    object = payload_object(payload)

    stripe_id(object["payment_method"]) ||
      get_in(object, ["payment_method_details", "id"]) ||
      Map.get(payload, "provider_payment_method_ref")
  end

  defp extract_local_payment_intent_id(payload) do
    object = payload_object(payload)
    metadata = object["metadata"] || %{}
    metadata["local_intent_id"] || Map.get(payload, "local_payment_intent_id")
  end

  defp extract_action_url(payload) do
    object = payload_object(payload)
    get_in(object, ["next_action", "redirect_to_url", "url"]) || Map.get(payload, "action_url")
  end

  defp extract_client_secret(payload) do
    object = payload_object(payload)
    object["client_secret"] || Map.get(payload, "provider_client_secret")
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
              "charge.succeeded",
              "setup_intent.succeeded"
            ],
       do: :succeeded

  defp normalize_status(event_type)
       when event_type in [
              "payment_intent.requires_action",
              "payment_intent.requires_confirmation"
            ],
       do: :requires_action

  defp normalize_status(event_type)
       when event_type in [
              "checkout.session.expired",
              "payment_intent.payment_failed",
              "charge.failed",
              "setup_intent.setup_failed",
              "setup_intent.canceled"
            ],
       do: :failed

  defp normalize_status(_event_type), do: :unknown

  defp payload_object(payload) when is_map(payload) do
    get_in(payload, ["data", "object"]) || Map.get(payload, "data_object") || %{}
  end

  defp maybe_put_payment_line_item(form, :payment, amount_minor, currency, order_ref) do
    Map.merge(form, %{
      "line_items[0][price_data][currency]" => stripe_currency(currency),
      "line_items[0][price_data][product_data][name]" => "Order #{order_ref}",
      "line_items[0][price_data][unit_amount]" => Integer.to_string(amount_minor),
      "line_items[0][quantity]" => "1"
    })
  end

  defp maybe_put_payment_line_item(form, _checkout_mode, _amount_minor, _currency, _order_ref),
    do: form

  defp maybe_put_payment_intent_data(form, :payment, metadata, currency, save_for_off_session?) do
    form
    |> Map.put("payment_intent_data[metadata][checkout_key]", metadata["checkout_key"])
    |> Map.put("payment_intent_data[metadata][local_intent_id]", metadata["local_intent_id"])
    |> Map.put("payment_intent_data[metadata][order_id]", metadata["order_id"])
    |> Map.put("payment_intent_data[metadata][order_ref]", metadata["order_ref"])
    |> Map.put(
      "payment_intent_data[metadata][payment_intent_key]",
      metadata["payment_intent_key"]
    )
    |> maybe_put_setup_future_usage(save_for_off_session?)
    |> Map.put("payment_intent_data[currency]", stripe_currency(currency))
  end

  defp maybe_put_payment_intent_data(form, _checkout_mode, _metadata, _currency, _save?),
    do: form

  defp maybe_put_setup_future_usage(form, true),
    do: Map.put(form, "payment_intent_data[setup_future_usage]", "off_session")

  defp maybe_put_setup_future_usage(form, _value), do: form

  defp maybe_put_setup_intent_data(form, :setup, metadata, currency) do
    form
    |> Map.put("setup_intent_data[metadata][checkout_key]", metadata["checkout_key"])
    |> Map.put("setup_intent_data[metadata][currency]", String.upcase(currency))
    |> Map.put("setup_intent_data[metadata][local_intent_id]", metadata["local_intent_id"])
    |> Map.put("setup_intent_data[metadata][order_id]", metadata["order_id"])
    |> Map.put("setup_intent_data[metadata][order_ref]", metadata["order_ref"])
    |> Map.put("setup_intent_data[metadata][payment_intent_key]", metadata["payment_intent_key"])
  end

  defp maybe_put_setup_intent_data(form, _checkout_mode, _metadata, _currency), do: form

  defp setup_intent_amount(event_type)
       when event_type in [
              "setup_intent.succeeded",
              "setup_intent.setup_failed",
              "setup_intent.canceled"
            ],
       do: 0

  defp setup_intent_amount(_event_type), do: nil

  defp stripe_post(path, form, idempotency_key, opts) do
    with {:ok, config} <- stripe_config(opts),
         request_opts <- stripe_request_opts(config, path, form, idempotency_key),
         {:ok, response} <- ReqClient.post(request_opts[:url], Keyword.delete(request_opts, :url)) do
      {:ok, response}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp stripe_request_opts(config, path, form, idempotency_key) do
    config.request_options
    |> Keyword.merge(
      url: stripe_url(config.api_base_url, path),
      form: form,
      headers: stripe_headers(config, idempotency_key),
      retry: false
    )
  end

  defp stripe_headers(config, idempotency_key) do
    [
      {"authorization", "Bearer #{config.secret_key}"},
      {"idempotency-key", idempotency_key},
      {"stripe-version", config.api_version}
    ]
  end

  defp stripe_url(base_url, path) do
    "#{String.trim_trailing(base_url, "/")}#{path}"
  end

  defp stripe_config(opts) do
    payments = Application.get_env(:store, :payments, [])
    stripe = Keyword.get(payments, :stripe, [])

    config = %{
      api_base_url: Keyword.get(stripe, :api_base_url, @default_api_base_url),
      api_version: Keyword.get(stripe, :api_version, @default_api_version),
      request_options: Keyword.get(stripe, :request_options, []),
      secret_key: Keyword.get(opts, :secret_key) || Keyword.get(stripe, :secret_key)
    }

    case config.secret_key do
      secret_key when is_binary(secret_key) and secret_key != "" ->
        {:ok, config}

      _ ->
        {:error, Error.new("PAYMENT_PROVIDER_DOWN", "stripe secret key is not configured")}
    end
  end

  defp extract_payment_intent_response(%{status: status, body: body})
       when status in 200..299 and is_map(body),
       do: {:ok, body}

  defp extract_payment_intent_response(%{status: 402, body: body}) when is_map(body) do
    case get_in(body, ["error", "payment_intent"]) do
      payment_intent when is_map(payment_intent) -> {:ok, payment_intent}
      _ -> stripe_error(%{status: 402, body: body})
    end
  end

  defp extract_payment_intent_response(response), do: stripe_error(response)

  defp stripe_error(%{status: status, body: body}) do
    message =
      body
      |> stripe_error_message()

    code =
      cond do
        status == 408 -> "PAYMENT_PROVIDER_TIMEOUT"
        status >= 500 -> "PAYMENT_PROVIDER_DOWN"
        true -> "PAYMENT_PROCESSING_FAILED"
      end

    {:error, Error.new(code, message, %{provider: "stripe", status: status})}
  end

  defp stripe_error_message(%{"error" => %{"message" => message}})
       when is_binary(message) and message != "",
       do: message

  defp stripe_error_message(%{"error" => %{"code" => code}})
       when is_binary(code) and code != "",
       do: "stripe request failed: #{code}"

  defp stripe_error_message(_body), do: "stripe request failed"

  defp transport_error(reason) do
    Error.new("PAYMENT_PROVIDER_DOWN", Exception.message(reason), %{provider: "stripe"})
  end

  defp normalize_charge_status(%{"status" => "succeeded"}, _response), do: :succeeded

  defp normalize_charge_status(%{"status" => status}, _response)
       when status in ["requires_action", "requires_confirmation"],
       do: :requires_action

  defp normalize_charge_status(%{"status" => status}, response)
       when status in ["requires_payment_method", "canceled"] do
    if response.status == 402, do: :failed, else: :failed
  end

  defp normalize_charge_status(_payment_intent, %{status: 402}), do: :failed
  defp normalize_charge_status(_payment_intent, _response), do: :failed

  defp stripe_id(%{"id" => id}) when is_binary(id), do: id
  defp stripe_id(id) when is_binary(id), do: id
  defp stripe_id(_value), do: nil

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
    case attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new("VALIDATION_ERROR", "#{key} is required")}
    end
  end

  defp fetch_required_integer(attrs, key) do
    case attr(attrs, key) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, Error.new("VALIDATION_ERROR", "#{key} must be a non-negative integer")}
    end
  end

  defp derive_checkout_mode(amount_minor, explicit_mode, has_subscription_lines?) do
    case normalize_checkout_mode(explicit_mode) do
      {:ok, checkout_mode} ->
        checkout_mode

      :error ->
        if has_subscription_lines? and amount_minor == 0, do: :setup, else: :payment
    end
  end

  defp normalize_checkout_mode(nil), do: :error
  defp normalize_checkout_mode(:payment), do: {:ok, :payment}
  defp normalize_checkout_mode(:setup), do: {:ok, :setup}
  defp normalize_checkout_mode("payment"), do: {:ok, :payment}
  defp normalize_checkout_mode("setup"), do: {:ok, :setup}
  defp normalize_checkout_mode(_value), do: :error

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp truthy_attr?(attrs, key) do
    case attr(attrs, key) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp stripe_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.downcase()
  end
end
