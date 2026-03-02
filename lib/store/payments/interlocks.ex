defmodule Store.Payments.Interlocks do
  @moduledoc """
  Checkout and payment replay interlocks for idempotent intent creation and paid apply-once flow.
  """

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Orders.Order
  alias Store.Payments.{PaymentAttempt, PaymentIntent, ProviderEvent, WebhookReceipt}
  alias Store.Repo
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency

  @type payment_intent_request :: %{
          required(:order_id) => String.t(),
          required(:amount_received_minor) => integer(),
          required(:currency) => String.t(),
          optional(:provider) => String.t(),
          optional(:payment_intent_key) => String.t()
        }

  @spec create_or_reuse_payment_intent(payment_intent_request(), keyword()) ::
          {:ok,
           %{
             payment_intent: PaymentIntent.t(),
             payment_intent_key: String.t(),
             duplicate?: boolean()
           }}
          | {:error, Error.t() | term()}
  def create_or_reuse_payment_intent(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    ash_opts = payment_ash_opts(opts)

    with {:ok, request} <- normalize_payment_intent_request(attrs),
         {:ok, existing_by_key} <- find_payment_intent_by_key(request.payment_intent_key),
         {:ok, intent, duplicate?} <-
           create_or_reuse_payment_intent_record(request, existing_by_key, ash_opts) do
      {:ok,
       %{
         payment_intent: intent,
         payment_intent_key: request.payment_intent_key,
         duplicate?: duplicate?
       }}
    end
  end

  @spec process_payment_webhook_receipt(WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt(%WebhookReceipt{} = receipt, _opts \\ []) do
    with {:ok, payload} <- decode_webhook_payload(receipt.raw_body),
         {:ok, payment_intent_id} <- extract_payment_intent_id(payload),
         {:ok, event_type} <- extract_payment_event_type(payload),
         true <- success_event?(event_type),
         {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id),
         {:ok, provider_event_id} <- extract_provider_event_id(payload, receipt.id),
         {:ok, provider_event_key} <-
           ingest_provider_event(receipt, payload, event_type, provider_event_id),
         {:ok, _attempt} <-
           record_payment_attempt(
             payment_intent,
             receipt,
             provider_event_id,
             provider_event_key,
             event_type,
             payload
           ),
         {:ok, _result} <-
           apply_payment_success_once(payment_intent, provider_event_key: provider_event_key) do
      :ok
    else
      false -> {:discard, "not a payment success event"}
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply_payment_success_once(PaymentIntent.t() | String.t(), keyword()) ::
          {:ok, %{applied?: boolean(), order: Order.t(), payment_intent: PaymentIntent.t()}}
          | {:error, Error.t() | term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ [])

  def apply_payment_success_once(%PaymentIntent{} = payment_intent, _opts) do
    with true <- is_binary(payment_intent.order_id),
         {:ok, order} <- fetch_order(payment_intent.order_id),
         {:ok, result, notifications} <-
           Repo.transaction(fn -> run_apply_payment_success_once(payment_intent, order) end)
           |> normalize_transaction_result(),
         :ok <-
           AshNotifications.notify_post_commit(
             notifications,
             context: %{
               flow: :apply_payment_success_once,
               order_id: order.id,
               payment_intent_id: payment_intent.id
             }
           ) do
      {:ok, result}
    else
      false ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "payment intent is not attached to an order")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_payment_success_once(payment_intent_id, opts)
      when is_binary(payment_intent_id) and is_list(opts) do
    with {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id) do
      apply_payment_success_once(payment_intent, opts)
    end
  end

  defp normalize_payment_intent_request(attrs) do
    provider = attr(attrs, :provider, "stripe")

    order_id = attr(attrs, :order_id)
    amount_received_minor = attr(attrs, :amount_received_minor)
    currency = attr(attrs, :currency)

    payment_intent_key =
      attr(
        attrs,
        :payment_intent_key,
        if(
          is_binary(order_id) and is_integer(amount_received_minor) and is_binary(currency),
          do: Idempotency.payment_intent_key(order_id, amount_received_minor, currency, provider),
          else: nil
        )
      )

    request = %{
      order_id: order_id,
      amount_received_minor: amount_received_minor,
      currency: currency,
      provider: provider,
      payment_intent_key: payment_intent_key
    }

    with :ok <- require_binary(request.order_id, "order_id is required"),
         :ok <-
           require_non_negative_integer(
             request.amount_received_minor,
             "amount_received_minor must be >= 0"
           ),
         :ok <- require_binary(request.currency, "currency is required"),
         :ok <- require_binary(request.provider, "provider is required"),
         :ok <- require_binary(request.payment_intent_key, "payment_intent_key is required") do
      {:ok, request}
    end
  end

  defp create_or_reuse_payment_intent_record(_request, %PaymentIntent{} = intent, _ash_opts) do
    {:ok, intent, true}
  end

  defp create_or_reuse_payment_intent_record(request, nil, ash_opts) do
    with :ok <- ensure_no_succeeded_intent(request.order_id),
         :ok <- ensure_no_in_flight_intent(request.order_id),
         {:ok, intent} <- create_or_reuse_intent(request, ash_opts) do
      {:ok, intent, false}
    end
  end

  defp create_or_reuse_intent(request, ash_opts) do
    attrs = %{
      order_id: request.order_id,
      amount_received_minor: request.amount_received_minor,
      currency: String.upcase(request.currency),
      payment_intent_key: request.payment_intent_key
    }

    PaymentIntent
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create(ash_opts)
    |> case do
      {:ok, intent} ->
        {:ok, intent}

      {:error, error} ->
        normalize_create_or_reuse_error(error)
    end
  end

  defp normalize_create_or_reuse_error(error) do
    message = Exception.message(error)

    cond do
      String.contains?(message, "payment_intents_unique_in_flight_order_id_index") ->
        {:error,
         Error.new(
           "PAYMENT_INTENT_DUPLICATE",
           "payment intent already in-flight for order"
         )}

      String.contains?(message, "payment_intents_unique_payment_intent_key_index") ->
        {:error, Error.new("PAYMENT_INTENT_DUPLICATE", "payment intent key already exists")}

      true ->
        {:error, error}
    end
  end

  defp find_payment_intent_by_key(payment_intent_key) when is_binary(payment_intent_key) do
    query = PaymentIntent |> Ash.Query.filter(expr(payment_intent_key == ^payment_intent_key))

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [intent | _]} -> {:ok, intent}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_no_succeeded_intent(order_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(order_id == ^order_id and state == :succeeded))

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, []} ->
        :ok

      {:ok, [_intent | _]} ->
        {:error, Error.new("PAYMENT_ALREADY_SUCCEEDED", "payment already succeeded for order")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_no_in_flight_intent(order_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(order_id == ^order_id and (state == :submitted or state == :requires_action))
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, []} ->
        :ok

      {:ok, [_intent | _]} ->
        {:error,
         Error.new("PAYMENT_INTENT_DUPLICATE", "payment intent already in-flight for order")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_webhook_payload(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:discard, "invalid webhook payload"}
    end
  end

  defp decode_webhook_payload(_raw_body), do: {:discard, "invalid webhook payload"}

  defp extract_payment_intent_id(payload) when is_map(payload) do
    payment_intent_id =
      Map.get(payload, "payment_intent_id") ||
        get_in(payload, ["data", "object", "id"]) ||
        get_in(payload, ["payment_intent", "id"])

    case payment_intent_id do
      value when is_binary(value) -> {:ok, value}
      _ -> {:discard, "missing payment_intent_id in webhook payload"}
    end
  end

  defp extract_payment_intent_id(_payload), do: {:discard, "invalid webhook payload"}

  defp extract_payment_event_type(payload) when is_map(payload) do
    event_type =
      Map.get(payload, "event_type") || Map.get(payload, "type") || "payment_intent.succeeded"

    case event_type do
      value when is_binary(value) -> {:ok, value}
      _ -> {:discard, "missing event_type"}
    end
  end

  defp extract_payment_event_type(_payload), do: {:discard, "invalid webhook payload"}

  defp success_event?(event_type) when is_binary(event_type) do
    event_type in ["payment_intent.succeeded", "charge.succeeded"]
  end

  defp extract_provider_event_id(payload, fallback_receipt_id) do
    event_id =
      Map.get(payload, "provider_event_id") || Map.get(payload, "event_id") ||
        Map.get(payload, "id")

    case event_id do
      value when is_binary(value) -> {:ok, value}
      _ -> {:ok, "receipt:#{fallback_receipt_id}"}
    end
  end

  defp ingest_provider_event(receipt, payload, event_type, provider_event_id) do
    attrs = %{
      provider: receipt.provider,
      provider_event_id: provider_event_id,
      provider_event_key: Idempotency.provider_event_key(receipt.provider, provider_event_id),
      event_type: event_type,
      payload_sha256: Idempotency.payload_hash(payload),
      received_at: receipt.received_at
    }

    ProviderEvent
    |> Ash.Changeset.for_create(:ingest, attrs, context: %{system?: true})
    |> Ash.create(payment_ash_opts([]))
    |> case do
      {:ok, event} -> {:ok, event.provider_event_key}
      {:error, error} -> {:error, error}
    end
  end

  defp record_payment_attempt(
         payment_intent,
         receipt,
         provider_event_id,
         provider_event_key,
         event_type,
         payload
       ) do
    attrs = %{
      payment_intent_id: payment_intent.id,
      provider: receipt.provider,
      provider_event_id: provider_event_id,
      provider_event_key: provider_event_key,
      attempt_key: payment_attempt_key(provider_event_key, payment_intent.id, event_type),
      outcome: payment_attempt_outcome(event_type),
      payload_sha256: Idempotency.payload_hash(payload),
      attempted_at: DateTime.utc_now()
    }

    PaymentAttempt
    |> Ash.Changeset.for_create(:record, attrs, context: %{system?: true})
    |> Ash.create(payment_ash_opts([]))
  end

  defp payment_attempt_key(provider_event_key, payment_intent_id, event_type) do
    "pay_attempt:#{provider_event_key}:pi:#{payment_intent_id}:event:#{event_type}"
  end

  defp payment_attempt_outcome(event_type)
       when event_type in ["payment_intent.succeeded", "charge.succeeded"],
       do: "succeeded"

  defp payment_attempt_outcome(_event_type), do: "ignored"

  defp run_apply_payment_success_once(payment_intent, order) do
    application_key = "paid_apply:order:#{order.id}"

    with {:ok, status} <- insert_payment_application(order.id, payment_intent.id, application_key),
         {:ok, updated_intent, intent_notifications} <-
           maybe_mark_payment_intent_succeeded(payment_intent),
         {:ok, updated_order, order_notifications} <- maybe_mark_order_paid(order),
         {:ok, _consume_result} <-
           Store.Orders.consume_reservations_for_order(order.id, context: %{system?: true}) do
      notifications = intent_notifications ++ order_notifications
      {:ok, apply_once_result(status, updated_order, updated_intent), notifications}
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, other} -> Repo.rollback(other)
    end
  end

  defp apply_once_result(:inserted, order, payment_intent) do
    %{applied?: true, order: order, payment_intent: payment_intent}
  end

  defp apply_once_result(:exists, order, payment_intent) do
    %{applied?: false, order: order, payment_intent: payment_intent}
  end

  defp insert_payment_application(order_id, payment_intent_id, application_key) do
    query = """
    INSERT INTO payment_applications (
      id, order_id, payment_intent_id, application_key, applied_at, inserted_at, updated_at
    )
    VALUES (
      uuid_generate_v7(), $1::text::uuid, $2::text::uuid, $3, (now() AT TIME ZONE 'utc'),
      (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
    )
    ON CONFLICT (application_key) DO NOTHING
    RETURNING id::text
    """

    case SQL.query(Repo, query, [order_id, payment_intent_id, application_key]) do
      {:ok, %{rows: [[_id]]}} ->
        {:ok, :inserted}

      {:ok, %{rows: []}} ->
        {:ok, :exists}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to record payment application")}
    end
  end

  defp maybe_mark_payment_intent_succeeded(%PaymentIntent{state: :succeeded} = payment_intent),
    do: {:ok, payment_intent, []}

  defp maybe_mark_payment_intent_succeeded(%PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action] do
    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts(return_notifications?: true))
    |> case do
      {:ok, updated_intent, notifications} -> {:ok, updated_intent, notifications}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_payment_intent_succeeded(_payment_intent) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent is not in a success-transitionable state"
     )}
  end

  defp maybe_mark_order_paid(%Order{state: :paid} = order), do: {:ok, order, []}

  defp maybe_mark_order_paid(%Order{state: :pending_payment} = order) do
    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update(order_ash_opts(return_notifications?: true))
    |> case do
      {:ok, updated_order, notifications} -> {:ok, updated_order, notifications}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_order_paid(_order) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "order is not in pending_payment state")}
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, order_ash_opts([])) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found for payment intent")}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_payment_intent(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:discard, "payment intent not found"}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_transaction_result({:ok, {:ok, result, notifications}})
       when is_list(notifications),
       do: {:ok, result, notifications}

  defp normalize_transaction_result({:ok, other}) do
    {:error,
     Error.new("INTERNAL_ERROR", "invalid transaction result shape", %{
       result: inspect(other)
     })}
  end

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp payment_ash_opts(opts) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    opts
    |> Keyword.put(:domain, Store.Payments)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp order_ash_opts(opts) do
    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.put_new(:system?, true)

    opts
    |> Keyword.put(:domain, Store.Orders)
    |> Keyword.put(:authorize?, false)
    |> Keyword.put(:context, context)
  end

  defp require_binary(value, _message) when is_binary(value), do: :ok
  defp require_binary(_value, message), do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp require_non_negative_integer(value, _message) when is_integer(value) and value >= 0,
    do: :ok

  defp require_non_negative_integer(_value, message),
    do: {:error, Error.new("VALIDATION_ERROR", message)}

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
