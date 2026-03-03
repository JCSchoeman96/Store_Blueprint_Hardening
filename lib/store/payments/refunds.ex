defmodule Store.Payments.Refunds do
  @moduledoc """
  Refund orchestration with lock-based bound checks and replay-safe webhook finalization.
  """

  import Ash.Expr
  require Ash.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias Store.Admin.Authorization
  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem, RefundAdjustment}
  alias Store.Payments.{PaymentIntent, ProviderEvent, Refund, RefundAttempt, WebhookReceipt}
  alias Store.Repo
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency
  alias Store.Support.Time

  @step_up_window_minutes 15

  @type request_attrs :: %{
          required(:order_id) => String.t(),
          required(:payment_intent_id) => String.t(),
          required(:requested_amount_minor) => integer(),
          required(:currency) => String.t(),
          optional(:reason) => String.t(),
          optional(:line_item_ids) => [String.t()]
        }

  @spec request_refund(request_attrs(), keyword()) ::
          {:ok, Refund.t()} | {:error, Error.t() | term()}
  def request_refund(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    actor = Keyword.get(opts, :actor)
    context = Keyword.get(opts, :context, %{})
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, request} <- normalize_request(attrs),
         :ok <- enforce_refund_actor!(actor, context, authorize?) do
      request_refund_transaction(request, actor, context, authorize?)
    end
  end

  defp request_refund_transaction(request, actor, context, authorize?) do
    with {:ok, refund, notifications} <-
           Repo.transaction(fn ->
             run_locked_refund_request(request, actor, context, authorize?)
           end)
           |> normalize_transaction_result(),
         :ok <-
           AshNotifications.notify_post_commit(
             notifications,
             context: %{
               flow: :request_refund,
               order_id: request.order_id,
               payment_intent_id: request.payment_intent_id
             }
           ),
         :ok <- maybe_enqueue_refund_requested(refund) do
      {:ok, refund}
    end
  end

  defp run_locked_refund_request(request, actor, context, authorize?) do
    with {:ok, payment_intent} <- lock_payment_intent_for_update(request.payment_intent_id),
         :ok <- ensure_refundable_payment_intent(payment_intent),
         :ok <- ensure_matching_order_id(request.order_id, payment_intent.order_id),
         {:ok, order} <- fetch_order(request.order_id),
         :ok <- ensure_order_state_allows_refund(order),
         :ok <- ensure_matching_currency(request.currency, payment_intent.currency),
         {:ok, existing_refund} <-
           find_refund_by_idempotency_key_for_update(request.idempotency_key),
         {:ok, refund, notifications} <-
           create_or_reuse_refund(
             existing_refund,
             request,
             payment_intent,
             actor,
             context,
             authorize?
           ) do
      {:ok, refund, notifications}
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, other} -> Repo.rollback(other)
    end
  end

  defp normalize_transaction_result({:ok, {:ok, refund, notifications}})
       when is_list(notifications),
       do: {:ok, refund, notifications}

  defp normalize_transaction_result({:ok, other}) do
    {:error,
     Error.new("INTERNAL_ERROR", "invalid transaction result shape", %{
       result: inspect(other)
     })}
  end

  defp normalize_transaction_result({:error, %Error{} = error}), do: {:error, error}
  defp normalize_transaction_result({:error, other}), do: {:error, other}

  @spec process_refund_webhook_receipt(WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt(%WebhookReceipt{} = receipt, _opts \\ []) do
    with {:ok, payload} <- decode_webhook_payload(receipt.raw_body),
         {:ok, event_type} <- extract_event_type(payload),
         true <- refund_event?(event_type),
         {:ok, provider_event_id} <- extract_provider_event_id(payload),
         {:ok, provider_event_key} <-
           ingest_provider_event(receipt, payload, event_type, provider_event_id),
         {:ok, refund} <- find_refund_for_event(payload),
         {:ok, _attempt_or_duplicate} <-
           record_refund_attempt(
             refund,
             receipt,
             payload,
             provider_event_id,
             provider_event_key,
             event_type
           ),
         :ok <- apply_refund_event(refund, payload, event_type) do
      :ok
    else
      false -> {:discard, "not a refund event"}
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec refundable_base_minor(String.t(), integer()) :: {:ok, integer()} | {:error, Error.t()}
  def refundable_base_minor(order_id, captured_amount_minor)
      when is_binary(order_id) and is_integer(captured_amount_minor) do
    with {:ok, line_total} <- sum_order_line_item_net_total(order_id),
         {:ok, adjustment_total} <- sum_order_adjustments(order_id) do
      snapshot_total = line_total + adjustment_total
      {:ok, min(captured_amount_minor, snapshot_total)}
    end
  end

  @spec refundable_remaining_minor(String.t(), String.t(), integer()) ::
          {:ok, integer()} | {:error, Error.t()}
  def refundable_remaining_minor(order_id, payment_intent_id, captured_amount_minor)
      when is_binary(order_id) and is_binary(payment_intent_id) and
             is_integer(captured_amount_minor) do
    with {:ok, base_minor} <- refundable_base_minor(order_id, captured_amount_minor),
         {:ok, successful_refunds_minor} <- sum_successful_refunds(order_id, payment_intent_id) do
      {:ok, base_minor - successful_refunds_minor}
    end
  end

  @spec refundable_request_remaining_minor(String.t(), String.t(), integer()) ::
          {:ok, integer()} | {:error, Error.t()}
  def refundable_request_remaining_minor(order_id, payment_intent_id, captured_amount_minor)
      when is_binary(order_id) and is_binary(payment_intent_id) and
             is_integer(captured_amount_minor) do
    with {:ok, base_minor} <- refundable_base_minor(order_id, captured_amount_minor),
         {:ok, committed_refunds_minor} <- sum_committed_refunds(order_id, payment_intent_id) do
      {:ok, base_minor - committed_refunds_minor}
    end
  end

  defp create_or_reuse_refund(
         %Refund{} = existing_refund,
         request,
         _payment_intent,
         _actor,
         _context,
         _authorize?
       ) do
    request_fingerprint =
      Idempotency.refund_request_fingerprint(
        request.scope_hash,
        request.requested_amount_minor,
        request.currency,
        request.reason
      )

    existing_fingerprint =
      Idempotency.refund_request_fingerprint(
        existing_refund.scope_hash,
        existing_refund.requested_amount_minor,
        existing_refund.currency,
        existing_refund.reason
      )

    if request_fingerprint == existing_fingerprint do
      {:ok, existing_refund, []}
    else
      {:error,
       Error.new(
         "IDEMPOTENCY_KEY_REUSE_MISMATCH",
         "idempotency key reused with different refund payload"
       )}
    end
  end

  defp create_or_reuse_refund(nil, request, payment_intent, actor, context, _authorize?) do
    with {:ok, remaining_minor} <-
           refundable_request_remaining_minor(
             request.order_id,
             payment_intent.id,
             payment_intent.amount_received_minor
           ),
         :ok <-
           ensure_requested_amount_within_remaining(
             request.requested_amount_minor,
             remaining_minor
           ) do
      attrs = %{
        order_id: request.order_id,
        payment_intent_id: request.payment_intent_id,
        provider: request.provider,
        requested_amount_minor: request.requested_amount_minor,
        currency: request.currency,
        reason: request.reason,
        scope_hash: request.scope_hash,
        idempotency_key: request.idempotency_key,
        requested_by_user_id: actor && Map.get(actor, :id),
        requested_at: DateTime.utc_now()
      }

      Refund
      |> Ash.Changeset.for_create(:request, attrs, context: context)
      |> Ash.create(
        domain: Store.Payments,
        actor: actor,
        context: context,
        authorize?: false,
        return_notifications?: true
      )
      |> case do
        {:ok, refund, notifications} ->
          {:ok, refund, notifications}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp decode_webhook_payload(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:discard, "invalid refund webhook payload"}
    end
  end

  defp decode_webhook_payload(_), do: {:discard, "invalid refund webhook payload"}

  defp extract_event_type(payload) do
    case Map.get(payload, "event_type") || Map.get(payload, "type") do
      event_type when is_binary(event_type) -> {:ok, event_type}
      _ -> {:discard, "missing refund event_type"}
    end
  end

  defp refund_event?(event_type) when is_binary(event_type) do
    String.starts_with?(event_type, "refund.") or event_type == "charge.refunded"
  end

  defp extract_provider_event_id(payload) do
    event_id =
      Map.get(payload, "provider_event_id") ||
        Map.get(payload, "event_id") ||
        Map.get(payload, "id")

    case event_id do
      value when is_binary(value) -> {:ok, value}
      _ -> {:discard, "missing provider_event_id"}
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
    |> Ash.create(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, event} -> {:ok, event.provider_event_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_refund_for_event(payload) do
    idempotency_key =
      get_in(payload, ["refund", "idempotency_key"]) || Map.get(payload, "idempotency_key")

    provider_refund_id =
      get_in(payload, ["refund", "provider_refund_id"]) || get_in(payload, ["refund", "id"])

    with {:ok, maybe_refund} <- find_refund_by_idempotency_key(idempotency_key) do
      case maybe_refund do
        %Refund{} = refund ->
          {:ok, refund}

        nil ->
          find_refund_by_provider_refund_id(provider_refund_id)
      end
    end
  end

  defp find_refund_by_idempotency_key(nil), do: {:ok, nil}

  defp find_refund_by_idempotency_key(idempotency_key) when is_binary(idempotency_key) do
    query = Refund |> Ash.Query.filter(expr(idempotency_key == ^idempotency_key))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [refund | _]} -> {:ok, refund}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp find_refund_by_provider_refund_id(nil), do: {:discard, "refund not found for webhook"}

  defp find_refund_by_provider_refund_id(provider_refund_id) when is_binary(provider_refund_id) do
    query = Refund |> Ash.Query.filter(expr(provider_refund_id == ^provider_refund_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [refund | _]} -> {:ok, refund}
      {:ok, []} -> {:discard, "refund not found for webhook"}
      {:error, error} -> {:error, error}
    end
  end

  defp record_refund_attempt(
         refund,
         receipt,
         payload,
         provider_event_id,
         provider_event_key,
         event_type
       ) do
    case find_refund_attempt_by_provider_event_key(provider_event_key) do
      {:ok, %RefundAttempt{} = existing_attempt} ->
        {:ok, existing_attempt}

      {:ok, nil} ->
        with {:ok, sequence_no} <- next_refund_attempt_sequence_no(refund.id) do
          attrs = %{
            refund_id: refund.id,
            provider: receipt.provider,
            provider_event_id: provider_event_id,
            provider_event_key: provider_event_key,
            provider_refund_id: get_in(payload, ["refund", "id"]),
            outcome: refund_attempt_outcome(event_type),
            payload_sha256: Idempotency.payload_hash(payload),
            attempted_at: DateTime.utc_now(),
            sequence_no: sequence_no
          }

          RefundAttempt
          |> Ash.Changeset.for_create(:record, attrs, context: %{system?: true})
          |> Ash.create(domain: Store.Payments, authorize?: false, context: %{system?: true})
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_refund_attempt_by_provider_event_key(provider_event_key) do
    query = RefundAttempt |> Ash.Query.filter(expr(provider_event_key == ^provider_event_key))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [attempt | _]} -> {:ok, attempt}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp next_refund_attempt_sequence_no(refund_id) do
    query =
      "SELECT COALESCE(MAX(sequence_no), 0)::bigint FROM refund_attempts WHERE refund_id::text = $1"

    case SQL.query(Repo, query, [refund_id]) do
      {:ok, %{rows: [[max_sequence_no]]}} ->
        {:ok, max_sequence_no + 1}

      {:error, _} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to determine refund attempt sequence")}
    end
  end

  defp refund_attempt_outcome(event_type)
       when event_type in ["refund.succeeded", "charge.refunded"],
       do: "succeeded"

  defp refund_attempt_outcome("refund.failed"), do: "failed"
  defp refund_attempt_outcome(_), do: "ignored"

  defp apply_refund_event(refund, payload, "refund.failed") do
    finalize_refund_failure(refund, payload)
  end

  defp apply_refund_event(refund, payload, event_type)
       when event_type in ["refund.succeeded", "charge.refunded"] do
    finalize_refund_success(refund, payload)
  end

  defp apply_refund_event(_refund, _payload, _event_type), do: :ok

  defp finalize_refund_success(%Refund{state: :succeeded} = refund, _payload) do
    with :ok <- maybe_mark_order_refunded(refund.order_id, refund.payment_intent_id) do
      maybe_enqueue_refund_processed(refund)
    end
  end

  defp finalize_refund_success(%Refund{} = refund, payload) do
    attrs = %{
      provider_refund_id: get_in(payload, ["refund", "id"]),
      finalized_at: DateTime.utc_now()
    }

    with {:ok, updated_refund} <- update_refund(refund, :mark_succeeded, attrs),
         :ok <- ensure_refund_adjustment(updated_refund),
         :ok <-
           maybe_mark_order_refunded(updated_refund.order_id, updated_refund.payment_intent_id) do
      maybe_enqueue_refund_processed(updated_refund)
    end
  end

  defp finalize_refund_failure(%Refund{state: :failed}, _payload), do: :ok

  defp finalize_refund_failure(%Refund{} = refund, _payload) do
    refund
    |> update_refund(:mark_failed, %{finalized_at: DateTime.utc_now()})
    |> case do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_refund(refund, action, attrs) do
    refund
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp ensure_refund_adjustment(%Refund{} = refund) do
    query = RefundAdjustment |> Ash.Query.filter(expr(refund_id == ^refund.id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [_existing | _]} ->
        :ok

      {:ok, []} ->
        attrs = %{
          order_id: refund.order_id,
          refund_id: refund.id,
          currency: refund.currency,
          kind: "refund",
          amount_minor: -refund.requested_amount_minor,
          reason: refund.reason
        }

        RefundAdjustment
        |> Ash.Changeset.for_create(:create, attrs, context: %{system?: true})
        |> Ash.create(domain: Store.Orders, authorize?: false, context: %{system?: true})
        |> case do
          {:ok, _adjustment} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_mark_order_refunded(order_id, payment_intent_id) do
    with {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id),
         {:ok, order} <- fetch_order(order_id),
         {:ok, remaining_minor} <-
           refundable_remaining_minor(
             order_id,
             payment_intent_id,
             payment_intent.amount_received_minor
           ) do
      maybe_transition_order_refunded(order, remaining_minor)
    end
  end

  defp maybe_transition_order_refunded(%Order{state: :refunded}, _remaining_minor), do: :ok

  defp maybe_transition_order_refunded(%Order{state: state}, _remaining_minor)
       when state != :paid, do: :ok

  defp maybe_transition_order_refunded(%Order{}, remaining_minor) when remaining_minor > 0,
    do: :ok

  defp maybe_transition_order_refunded(%Order{} = order, _remaining_minor) do
    order
    |> Ash.Changeset.for_update(:mark_refunded, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Orders, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated_order} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("REFUND_NOT_ALLOWED", "order not found for refund")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [payment_intent | _]} ->
        {:ok, payment_intent}

      {:ok, []} ->
        {:error, Error.new("REFUND_NOT_ALLOWED", "payment intent not found for refund")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_refund_actor!(_actor, _context, false), do: :ok

  defp enforce_refund_actor!(actor, context, true) do
    cond do
      Authorization.has_any_role?(actor, [:super_admin, :admin]) == false ->
        {:error, Error.new("FORBIDDEN", "forbidden")}

      step_up_recent?(context, @step_up_window_minutes) == false ->
        {:error,
         Error.new("STEP_UP_REQUIRED", "step-up required", %{
           required_window_minutes: @step_up_window_minutes,
           step_up_last_at_utc: nil
         })}

      true ->
        :ok
    end
  end

  defp step_up_recent?(context, window_minutes) do
    window_usec = Time.minutes_to_usec(window_minutes)

    case Map.get(context, :step_up_at_mono_usec) do
      value when is_integer(value) ->
        Time.within_window_usec?(value, window_usec)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed_value, ""} -> Time.within_window_usec?(parsed_value, window_usec)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp normalize_request(attrs) do
    fields = extract_request_fields(attrs)

    with :ok <- validate_request_fields(fields) do
      {:ok, finalize_request_fields(fields)}
    end
  end

  defp extract_request_fields(attrs) do
    %{
      order_id: attr(attrs, :order_id),
      payment_intent_id: attr(attrs, :payment_intent_id),
      requested_amount_minor: attr(attrs, :requested_amount_minor),
      currency: attr(attrs, :currency),
      reason: attr(attrs, :reason, "unspecified"),
      provider: attr(attrs, :provider, "stripe"),
      provided_idempotency_key: attr(attrs, :idempotency_key),
      line_item_ids: attr(attrs, :line_item_ids, [])
    }
  end

  defp validate_request_fields(fields) do
    [
      require_binary(fields.order_id, "order_id is required"),
      require_binary(fields.payment_intent_id, "payment_intent_id is required"),
      require_positive_integer(
        fields.requested_amount_minor,
        "requested_amount_minor must be positive"
      ),
      require_binary(fields.currency, "currency is required"),
      require_binary(fields.reason, "reason must be a string"),
      require_binary(fields.provider, "provider must be a string"),
      require_list(fields.line_item_ids, "line_item_ids must be a list")
    ]
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp finalize_request_fields(fields) do
    scope_hash = Idempotency.refund_scope_hash(fields.line_item_ids)

    deterministic_idempotency_key =
      Idempotency.refund_idempotency_key(
        fields.order_id,
        fields.requested_amount_minor,
        fields.reason,
        scope_hash
      )

    idempotency_key =
      if is_binary(fields.provided_idempotency_key) do
        fields.provided_idempotency_key
      else
        deterministic_idempotency_key
      end

    %{
      order_id: fields.order_id,
      payment_intent_id: fields.payment_intent_id,
      requested_amount_minor: fields.requested_amount_minor,
      currency: fields.currency,
      reason: fields.reason,
      provider: fields.provider,
      scope_hash: scope_hash,
      idempotency_key: idempotency_key
    }
  end

  defp require_binary(value, _message) when is_binary(value), do: :ok

  defp require_binary(_value, message) do
    {:error, Error.new("VALIDATION_ERROR", message)}
  end

  defp require_positive_integer(value, _message) when is_integer(value) and value > 0, do: :ok

  defp require_positive_integer(_value, message) do
    {:error, Error.new("VALIDATION_ERROR", message)}
  end

  defp require_list(value, _message) when is_list(value), do: :ok

  defp require_list(_value, message) do
    {:error, Error.new("VALIDATION_ERROR", message)}
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp lock_payment_intent_for_update(payment_intent_id) do
    query = """
    SELECT id::text, state, amount_received_minor, currency, order_id::text
    FROM payment_intents
    WHERE id::text = $1
    FOR UPDATE
    """

    case SQL.query(Repo, query, [payment_intent_id]) do
      {:ok, %{rows: [[id, state, amount_received_minor, currency, order_id]]}} ->
        {:ok,
         %{
           id: id,
           state: state,
           amount_received_minor: amount_received_minor || 0,
           currency: currency,
           order_id: order_id
         }}

      {:ok, %{rows: []}} ->
        {:error, Error.new("REFUND_NOT_ALLOWED", "payment intent not found")}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to lock payment intent")}
    end
  end

  defp ensure_refundable_payment_intent(%{state: "succeeded"}), do: :ok

  defp ensure_refundable_payment_intent(_payment_intent) do
    {:error, Error.new("REFUND_NOT_ALLOWED", "refund requires succeeded payment intent")}
  end

  defp ensure_matching_order_id(order_id, order_id), do: :ok

  defp ensure_matching_order_id(_requested_order_id, _payment_order_id) do
    {:error, Error.new("REFUND_NOT_ALLOWED", "payment intent is not attached to requested order")}
  end

  defp ensure_matching_currency(currency, currency), do: :ok

  defp ensure_matching_currency(_requested_currency, _payment_currency) do
    {:error, Error.new("CURRENCY_MISMATCH", "refund currency must match payment intent currency")}
  end

  defp ensure_order_state_allows_refund(%Order{state: :paid}), do: :ok

  defp ensure_order_state_allows_refund(_order) do
    {:error, Error.new("REFUND_NOT_ALLOWED", "refund requires paid order state")}
  end

  defp find_refund_by_idempotency_key_for_update(idempotency_key) do
    query = """
    SELECT id::text
    FROM refunds
    WHERE idempotency_key = $1
    FOR UPDATE
    """

    case SQL.query(Repo, query, [idempotency_key]) do
      {:ok, %{rows: [[refund_id]]}} ->
        query = Refund |> Ash.Query.filter(expr(id == ^refund_id))

        case Ash.read(query, domain: Store.Payments, authorize?: false) do
          {:ok, [refund | _]} -> {:ok, refund}
          {:ok, []} -> {:ok, nil}
          {:error, error} -> {:error, error}
        end

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read existing refund")}
    end
  end

  defp ensure_requested_amount_within_remaining(requested_amount_minor, remaining_minor)
       when requested_amount_minor <= remaining_minor do
    :ok
  end

  defp ensure_requested_amount_within_remaining(_requested_amount_minor, _remaining_minor) do
    {:error, Error.new("REFUND_EXCEEDS_REFUNDABLE", "refund amount exceeds refundable remaining")}
  end

  defp sum_order_line_item_net_total(order_id) do
    query = OrderLineItem |> Ash.Query.filter(expr(order_id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false) do
      {:ok, line_items} ->
        total =
          Enum.reduce(line_items, 0, fn line_item, acc ->
            acc + (line_item.net_line_total_minor || 0)
          end)

        {:ok, total}

      {:error, _reason} ->
        {:error,
         Error.new("INTERNAL_ERROR", "unable to read order line items for refund calculation")}
    end
  end

  defp sum_order_adjustments(order_id) do
    query = OrderAdjustment |> Ash.Query.filter(expr(order_id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false) do
      {:ok, adjustments} ->
        total =
          Enum.reduce(adjustments, 0, fn adjustment, acc ->
            acc + (adjustment.amount_minor || 0)
          end)

        {:ok, total}

      {:error, _reason} ->
        {:error,
         Error.new("INTERNAL_ERROR", "unable to read order adjustments for refund calculation")}
    end
  end

  defp sum_successful_refunds(order_id, payment_intent_id) do
    query =
      Refund
      |> Ash.Query.filter(
        expr(
          order_id == ^order_id and payment_intent_id == ^payment_intent_id and
            state == :succeeded
        )
      )

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, refunds} ->
        total = Enum.reduce(refunds, 0, fn refund, acc -> acc + refund.requested_amount_minor end)
        {:ok, total}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read successful refunds")}
    end
  end

  defp sum_committed_refunds(order_id, payment_intent_id) do
    query =
      Refund
      |> Ash.Query.filter(
        expr(
          order_id == ^order_id and payment_intent_id == ^payment_intent_id and
            state in [:requested, :submitted, :succeeded]
        )
      )

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, refunds} ->
        total = Enum.reduce(refunds, 0, fn refund, acc -> acc + refund.requested_amount_minor end)
        {:ok, total}

      {:error, _reason} ->
        {:error, Error.new("INTERNAL_ERROR", "unable to read committed refunds")}
    end
  end

  defp maybe_enqueue_refund_requested(%Refund{} = refund) do
    case Store.Comms.enqueue_refund_requested_for_system(refund.id) do
      {:ok, _outbox} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "refund_requested_enqueue_failed refund_id=#{refund.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_refund_processed(%Refund{} = refund) do
    case Store.Comms.enqueue_refund_processed_for_system(refund.id) do
      {:ok, _outbox} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "refund_processed_enqueue_failed refund_id=#{refund.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end
end
