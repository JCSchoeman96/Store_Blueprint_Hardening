defmodule Store.Payments.Interlocks do
  @moduledoc """
  Checkout and payment replay interlocks for idempotent intent creation and paid apply-once flow.
  """

  import Ash.Expr
  require Ash.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Fulfillment.Facade, as: FulfillmentFacade
  alias Store.Orders.Order
  alias Store.Payments.{PaymentAttempt, PaymentIntent, ProviderEvent, Providers, WebhookReceipt}
  alias Store.Payments.Types.CanonicalReceipt
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.Error
  alias Store.Support.Governance.Idempotency
  alias Store.Workers.EnsureSubscriptionsForPaidOrderWorker
  alias Store.Workers.ReconcilePaidSubscriptionRenewalWorker

  @type payment_intent_request :: %{
          required(:order_id) => String.t(),
          required(:amount_received_minor) => integer(),
          required(:currency) => String.t(),
          optional(:provider) => Providers.provider(),
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
         {:ok, intent, duplicate?} <- create_or_reuse_payment_intent_record(request, ash_opts) do
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
    with :ok <- ensure_receipt_verified(receipt),
         :ok <- Providers.ensure_enabled_provider(receipt.provider),
         {:ok, payload} <- decode_webhook_payload(receipt.raw_body),
         {:ok, canonical} <- normalize_canonical_receipt(receipt.provider, payload),
         {:ok, payment_intent} <- fetch_payment_intent_for_canonical(canonical),
         {:ok, payment_intent} <-
           hydrate_payment_intent_provider_references(payment_intent, canonical),
         :ok <- validate_canonical_receipt_target(payment_intent, canonical),
         {:ok, provider_event_key} <- ingest_provider_event(receipt, canonical),
         {:ok, _attempt} <-
           record_payment_attempt(payment_intent, receipt, canonical, provider_event_key),
         {:ok, _result} <- apply_canonical_receipt(payment_intent, canonical, provider_event_key) do
      :ok
    else
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apply_payment_success_once(PaymentIntent.t() | String.t(), keyword()) ::
          {:ok, %{applied?: boolean(), order: Order.t(), payment_intent: PaymentIntent.t()}}
          | {:error, Error.t() | term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ [])

  def apply_payment_success_once(%PaymentIntent{} = payment_intent, _opts) do
    started_at = System.monotonic_time()

    result =
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
             ),
           :ok <- maybe_enqueue_fulfillment(result),
           :ok <- maybe_enqueue_digital_grants(result),
           :ok <- maybe_enqueue_subscriptions(result),
           :ok <- maybe_enqueue_order_receipt(result) do
        {:ok, result}
      else
        false ->
          {:error,
           Error.new("PAYMENT_EVENT_UNVERIFIED", "payment intent is not attached to an order")}

        {:error, reason} ->
          {:error, reason}
      end

    emit_apply_payment_success_once_telemetry(result, started_at)
    result
  end

  def apply_payment_success_once(payment_intent_id, opts)
      when is_binary(payment_intent_id) and is_list(opts) do
    with {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id) do
      apply_payment_success_once(payment_intent, opts)
    end
  end

  defp normalize_payment_intent_request(attrs) do
    order_id = attr(attrs, :order_id)
    amount_received_minor = attr(attrs, :amount_received_minor)
    currency = attr(attrs, :currency)
    provider_input = attr(attrs, :provider)

    with {:ok, provider} <- normalize_provider(provider_input),
         :ok <- Providers.ensure_enabled_provider(provider),
         :ok <- require_binary(order_id, "order_id is required"),
         :ok <-
           require_non_negative_integer(
             amount_received_minor,
             "amount_received_minor must be >= 0"
           ),
         :ok <- require_binary(currency, "currency is required"),
         payment_intent_key =
           attr(
             attrs,
             :payment_intent_key,
             if(
               is_binary(order_id) and is_integer(amount_received_minor) and is_binary(currency),
               do:
                 Idempotency.payment_intent_key(
                   order_id,
                   amount_received_minor,
                   currency,
                   provider
                 ),
               else: nil
             )
           ),
         :ok <- require_binary(payment_intent_key, "payment_intent_key is required") do
      {:ok,
       %{
         order_id: order_id,
         amount_received_minor: amount_received_minor,
         currency: currency,
         provider: provider,
         payment_intent_key: payment_intent_key
       }}
    end
  end

  defp create_or_reuse_payment_intent_record(request, ash_opts) do
    with {:ok, preflight_intent} <- read_preflight_payment_intent(request) do
      create_or_reuse_payment_intent_from_preflight(request, preflight_intent, ash_opts)
    end
  end

  defp create_or_reuse_payment_intent_from_preflight(
         request,
         %PaymentIntent{payment_intent_key: payment_intent_key} = intent,
         _ash_opts
       )
       when payment_intent_key == request.payment_intent_key do
    {:ok, intent, true}
  end

  defp create_or_reuse_payment_intent_from_preflight(
         _request,
         %PaymentIntent{state: :succeeded},
         _ash_opts
       ) do
    {:error, Error.new("PAYMENT_ALREADY_SUCCEEDED", "payment already succeeded for order")}
  end

  defp create_or_reuse_payment_intent_from_preflight(_request, %PaymentIntent{}, _ash_opts) do
    {:error, Error.new("PAYMENT_INTENT_DUPLICATE", "payment intent already in-flight for order")}
  end

  defp create_or_reuse_payment_intent_from_preflight(request, nil, ash_opts) do
    with {:ok, intent} <- create_or_reuse_intent(request, ash_opts) do
      {:ok, intent, payment_intent_duplicate?(intent)}
    end
  end

  defp create_or_reuse_intent(request, ash_opts) do
    attrs = %{
      order_id: request.order_id,
      amount_received_minor: request.amount_received_minor,
      currency: String.upcase(request.currency),
      provider: request.provider,
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

  defp read_preflight_payment_intent(request) do
    blocking_query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(
          payment_intent_key == ^request.payment_intent_key or
            (order_id == ^request.order_id and
               (state == :succeeded or state == :submitted or state == :requires_action))
        )
      )
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)

    case Ash.read(blocking_query, payment_ash_opts([])) do
      {:ok, intents} ->
        {:ok, prefer_preflight_intent(intents, request.payment_intent_key)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prefer_preflight_intent(intents, payment_intent_key) do
    Enum.find(intents, &(&1.payment_intent_key == payment_intent_key)) ||
      Enum.find(intents, &(&1.state == :succeeded)) ||
      List.first(intents)
  end

  defp emit_apply_payment_success_once_telemetry(result, started_at) do
    :telemetry.execute(
      [:store, :payments, :interlock_apply_payment_success_once],
      %{duration: System.monotonic_time() - started_at},
      %{
        replay: apply_payment_success_once_replay?(result),
        outcome: apply_payment_success_once_outcome(result)
      }
    )
  end

  defp apply_payment_success_once_replay?({:ok, %{applied?: false}}), do: true
  defp apply_payment_success_once_replay?(_result), do: false

  defp apply_payment_success_once_outcome({:ok, _result}), do: :ok
  defp apply_payment_success_once_outcome({:error, _reason}), do: :error
  defp apply_payment_success_once_outcome(_result), do: :unknown

  defp payment_intent_duplicate?(%PaymentIntent{} = intent) do
    Ash.Resource.get_metadata(intent, :upsert_skipped) == true
  end

  defp decode_webhook_payload(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:discard, "invalid webhook payload"}
    end
  end

  defp decode_webhook_payload(_raw_body), do: {:discard, "invalid webhook payload"}

  defp ensure_receipt_verified(%WebhookReceipt{verification_status: "verified"}), do: :ok

  defp ensure_receipt_verified(%WebhookReceipt{}) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "webhook receipt must be signature-verified before processing"
     )}
  end

  defp normalize_canonical_receipt(provider, payload) when is_map(payload) do
    with {:ok, normalized_provider} <- normalize_provider(provider) do
      Providers.normalize_webhook(normalized_provider, payload)
    end
  end

  defp normalize_canonical_receipt(_provider, _payload) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "unable to normalize provider receipt")}
  end

  defp fetch_payment_intent_for_canonical(%CanonicalReceipt{} = canonical) do
    provider_session_id = canonical.provider_session_id
    provider_payment_id = canonical.provider_payment_id
    local_payment_intent_id = canonical.local_payment_intent_id

    with {:ok, provider} <- normalize_provider(canonical.provider),
         {:ok, by_provider_session_id} <-
           fetch_payment_intent_by_provider_session_id(provider, provider_session_id),
         {:ok, by_provider_payment_id} <-
           fetch_payment_intent_by_provider_payment_id(provider, provider_payment_id),
         {:ok, by_local_payment_intent_id} <-
           fetch_payment_intent_if_present(local_payment_intent_id) do
      cond do
        match?(%PaymentIntent{}, by_provider_session_id) ->
          {:ok, by_provider_session_id}

        match?(%PaymentIntent{}, by_provider_payment_id) ->
          {:ok, by_provider_payment_id}

        match?(%PaymentIntent{}, by_local_payment_intent_id) ->
          {:ok, by_local_payment_intent_id}

        true ->
          fallback_fetch_payment_intent(
            provider_payment_id || provider_session_id || local_payment_intent_id
          )
      end
    end
  end

  defp fetch_payment_intent_by_provider_session_id(provider, provider_session_id)
       when is_atom(provider) and is_binary(provider_session_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(provider == ^provider and provider_session_id == ^provider_session_id)
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_by_provider_session_id(_provider, _provider_session_id),
    do: {:ok, nil}

  defp fetch_payment_intent_by_provider_payment_id(provider, provider_payment_id)
       when is_atom(provider) and is_binary(provider_payment_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(provider == ^provider and provider_payment_id == ^provider_payment_id)
      )

    case Ash.read(query, payment_ash_opts([])) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_by_provider_payment_id(_provider, _provider_payment_id),
    do: {:ok, nil}

  defp hydrate_payment_intent_provider_references(
         %PaymentIntent{} = payment_intent,
         %CanonicalReceipt{} = canonical
       ) do
    attrs =
      %{
        provider: payment_intent.provider,
        provider_payment_id: canonical.provider_payment_id || payment_intent.provider_payment_id,
        provider_session_id: canonical.provider_session_id || payment_intent.provider_session_id,
        provider_customer_ref:
          canonical.provider_customer_ref || payment_intent.provider_customer_ref,
        provider_payment_method_ref:
          canonical.provider_payment_method_ref || payment_intent.provider_payment_method_ref,
        provider_client_secret: canonical.client_secret || payment_intent.provider_client_secret
      }

    if provider_reference_update_needed?(payment_intent, attrs) do
      payment_intent
      |> Ash.Changeset.for_update(:set_provider_reference, attrs, context: %{system?: true})
      |> Ash.update(payment_ash_opts([]))
    else
      {:ok, payment_intent}
    end
  end

  defp fallback_fetch_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    case fetch_payment_intent(payment_intent_id) do
      {:ok, %PaymentIntent{} = payment_intent} -> {:ok, payment_intent}
      {:discard, _reason} -> {:discard, "payment intent not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_fetch_payment_intent(_payment_intent_id),
    do: {:discard, "payment intent not found"}

  defp fetch_payment_intent_if_present(payment_intent_id) when is_binary(payment_intent_id) do
    case fetch_payment_intent(payment_intent_id) do
      {:ok, payment_intent} -> {:ok, payment_intent}
      {:discard, _reason} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_payment_intent_if_present(_payment_intent_id), do: {:ok, nil}

  defp ensure_canonical_totals_match_order(%CanonicalReceipt{} = canonical, %Order{} = order) do
    order_amount = non_neg_int(order.grand_total_minor)
    order_currency = order.currency_code |> normalize_currency()
    receipt_currency = canonical.currency |> normalize_currency()

    cond do
      canonical.amount_minor != order_amount ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "receipt amount mismatch for finalized order totals"
         )}

      order_currency == nil or receipt_currency == nil ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "receipt/order currency must be present"
         )}

      order_currency != receipt_currency ->
        {:error, Error.new("CURRENCY_MISMATCH", "receipt currency does not match order totals")}

      true ->
        :ok
    end
  end

  defp ingest_provider_event(receipt, canonical) do
    with {:ok, provider} <- normalize_provider(canonical.provider || receipt.provider) do
      payload_hash =
        canonical.raw_payload
        |> Idempotency.payload_hash()

      attrs = %{
        provider: provider,
        provider_event_id: canonical.provider_event_id,
        provider_event_key: Idempotency.provider_event_key(provider, canonical.provider_event_id),
        event_type: canonical.event_type,
        payload_sha256: payload_hash,
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
  end

  defp record_payment_attempt(payment_intent, receipt, canonical, provider_event_key) do
    with {:ok, provider} <- normalize_provider(canonical.provider || receipt.provider) do
      payload_hash =
        canonical.raw_payload
        |> Idempotency.payload_hash()

      attrs = %{
        payment_intent_id: payment_intent.id,
        provider: provider,
        provider_event_id: canonical.provider_event_id,
        provider_event_key: provider_event_key,
        attempt_key:
          payment_attempt_key(provider_event_key, payment_intent.id, canonical.event_type),
        outcome: payment_attempt_outcome(canonical.status),
        payload_sha256: payload_hash,
        attempted_at: DateTime.utc_now()
      }

      PaymentAttempt
      |> Ash.Changeset.for_create(:record, attrs, context: %{system?: true})
      |> Ash.create(payment_ash_opts([]))
    end
  end

  defp payment_attempt_key(provider_event_key, payment_intent_id, event_type) do
    "pay_attempt:#{provider_event_key}:pi:#{payment_intent_id}:event:#{event_type}"
  end

  defp payment_attempt_outcome(:succeeded), do: "succeeded"
  defp payment_attempt_outcome(:failed), do: "failed"
  defp payment_attempt_outcome(_), do: "ignored"

  defp apply_canonical_receipt(
         %PaymentIntent{purpose: :subscription_payment_method_update} = payment_intent,
         %CanonicalReceipt{status: :succeeded},
         _provider_event_key
       ) do
    with {:ok, _updated_intent, _notifications} <-
           maybe_mark_payment_intent_succeeded(payment_intent),
         :ok <-
           SubscriptionsFacade.handle_payment_method_update_succeeded_for_system(
             payment_intent.id
           ) do
      {:ok, :updated}
    end
  end

  defp apply_canonical_receipt(
         payment_intent,
         %CanonicalReceipt{status: :succeeded},
         provider_event_key
       ) do
    apply_payment_success_once(payment_intent, provider_event_key: provider_event_key)
  end

  defp apply_canonical_receipt(
         %PaymentIntent{purpose: :subscription_payment_method_update} = payment_intent,
         %CanonicalReceipt{status: :failed, event_type: "setup_intent.canceled"},
         _provider_event_key
       ) do
    maybe_cancel_payment_intent(payment_intent)
  end

  defp apply_canonical_receipt(
         %PaymentIntent{purpose: :subscription_payment_method_update} = payment_intent,
         %CanonicalReceipt{status: :failed},
         _provider_event_key
       ) do
    maybe_mark_payment_intent_failed(payment_intent)
  end

  defp apply_canonical_receipt(
         payment_intent,
         %CanonicalReceipt{status: :failed},
         _provider_event_key
       ) do
    with {:ok, _result} <- maybe_mark_payment_intent_failed(payment_intent),
         :ok <- maybe_release_failed_renewal_reservations(payment_intent) do
      {:ok, :updated}
    end
  end

  defp apply_canonical_receipt(
         payment_intent,
         %CanonicalReceipt{status: :requires_action},
         _provider_event_key
       ) do
    with {:ok, _result} <- maybe_mark_payment_intent_requires_action(payment_intent),
         :ok <- maybe_release_failed_renewal_reservations(payment_intent) do
      {:ok, :updated}
    end
  end

  defp apply_canonical_receipt(_payment_intent, _canonical, _provider_event_key) do
    {:discard, "webhook event does not require payment state transition"}
  end

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

  defp maybe_mark_payment_intent_failed(%PaymentIntent{state: :failed}), do: {:ok, :noop}

  defp maybe_mark_payment_intent_failed(%PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action] do
    payment_intent
    |> Ash.Changeset.for_update(:mark_failed, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts([]))
    |> case do
      {:ok, _updated_intent} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_payment_intent_failed(%PaymentIntent{}), do: {:ok, :noop}

  defp maybe_cancel_payment_intent(%PaymentIntent{state: :cancelled}), do: {:ok, :noop}

  defp maybe_cancel_payment_intent(%PaymentIntent{state: state} = payment_intent)
       when state in [:created, :submitted, :requires_action] do
    payment_intent
    |> Ash.Changeset.for_update(:cancel, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts([]))
    |> case do
      {:ok, _updated_intent} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_cancel_payment_intent(%PaymentIntent{}), do: {:ok, :noop}

  defp maybe_mark_payment_intent_requires_action(%PaymentIntent{state: :requires_action}),
    do: {:ok, :noop}

  defp maybe_mark_payment_intent_requires_action(
         %PaymentIntent{state: :submitted} = payment_intent
       ) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_requires_action, %{}, context: %{system?: true})
    |> Ash.update(payment_ash_opts([]))
    |> case do
      {:ok, _updated_intent} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_mark_payment_intent_requires_action(%PaymentIntent{}), do: {:ok, :noop}

  defp maybe_release_failed_renewal_reservations(%PaymentIntent{order_id: order_id})
       when is_binary(order_id) do
    if renewal_order?(order_id) do
      case Store.Orders.release_reservations_for_order(order_id, context: %{system?: true}) do
        {:ok, _result} -> :ok
        {:error, %Error{} = error} -> {:error, error}
        {:error, other} -> {:error, other}
      end
    else
      :ok
    end
  end

  defp maybe_release_failed_renewal_reservations(%PaymentIntent{}), do: :ok

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

  defp renewal_order?(order_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, order_ash_opts([])) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, Error.new("ORDER_NOT_FOUND", "order not found for payment intent")}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_canonical_receipt_target(
         %PaymentIntent{purpose: :subscription_payment_method_update},
         %CanonicalReceipt{}
       ),
       do: :ok

  defp validate_canonical_receipt_target(
         %PaymentIntent{} = payment_intent,
         %CanonicalReceipt{} = canonical
       ) do
    with {:ok, order} <- fetch_order(payment_intent.order_id) do
      ensure_canonical_totals_match_order(canonical, order)
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

  defp maybe_enqueue_order_receipt(%{applied?: true, order: %Order{} = order}) do
    case Store.Comms.enqueue_order_receipt_for_system(order.id) do
      {:ok, _outbox} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "order_receipt_enqueue_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_order_receipt(_result), do: :ok

  defp maybe_enqueue_fulfillment(%{applied?: true, order: %Order{} = order}) do
    case SubscriptionsFacade.order_is_subscription_only_for_system(order.id) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        case FulfillmentFacade.enqueue_paid_order_fulfillment_for_system(order.id) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ensure_fulfillment_enqueue_failed order_id=#{order.id} reason=#{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "ensure_fulfillment_precheck_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_fulfillment(_result), do: :ok

  defp maybe_enqueue_digital_grants(%{applied?: true, order: %Order{} = order}) do
    case DigitalFacade.enqueue_paid_order_download_grants_for_system(order.id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "issue_digital_grants_enqueue_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_digital_grants(_result), do: :ok

  defp maybe_enqueue_subscriptions(%{applied?: true, order: %Order{} = order}) do
    case fetch_renewal_attempt_by_order_id(order.id) do
      {:ok, %RenewalAttempt{} = renewal_attempt} ->
        enqueue_renewal_reconciliation_job(order.id, renewal_attempt.id)

      {:ok, nil} ->
        maybe_enqueue_initial_subscriptions(order)

      {:error, reason} ->
        Logger.warning(
          "renewal_reconciliation_precheck_failed order_id=#{order.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_enqueue_subscriptions(_result), do: :ok

  defp maybe_enqueue_initial_subscriptions(%Order{} = order) do
    case SubscriptionsFacade.order_has_subscription_lines_for_system(order.id) do
      {:ok, true} -> enqueue_initial_subscription_job(order)
      {:ok, false} -> :ok
      {:error, reason} -> log_subscription_precheck_failure(order.id, reason)
    end
  end

  defp enqueue_initial_subscription_job(%Order{} = order) do
    %{"order_id" => order.id}
    |> EnsureSubscriptionsForPaidOrderWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> log_subscription_enqueue_failure(order.id, reason)
    end
  end

  defp log_subscription_precheck_failure(order_id, reason) do
    Logger.warning(
      "ensure_subscriptions_precheck_failed order_id=#{order_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp log_subscription_enqueue_failure(order_id, reason) do
    Logger.warning(
      "ensure_subscriptions_enqueue_failed order_id=#{order_id} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp fetch_renewal_attempt_by_order_id(order_id) when is_binary(order_id) do
    query =
      RenewalAttempt
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.limit(1)

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, [renewal_attempt | _]} -> {:ok, renewal_attempt}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_renewal_reconciliation_job(order_id, renewal_attempt_id) do
    %{"order_id" => order_id, "renewal_attempt_id" => renewal_attempt_id}
    |> ReconcilePaidSubscriptionRenewalWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "renewal_reconciliation_enqueue_failed order_id=#{order_id} reason=#{inspect(reason)}"
        )

        :ok
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

  defp normalize_provider(nil) do
    {:error,
     Error.new(
       "PAYMENT_PROVIDER_SELECTION_REQUIRED",
       "payment provider selection is required"
     )}
  end

  defp normalize_provider(provider_input) do
    case Providers.normalize_provider(provider_input) do
      :unknown ->
        {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported")}

      known ->
        if Providers.known_provider?(known) do
          {:ok, known}
        else
          {:error, Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "payment provider is unsupported")}
        end
    end
  end

  defp normalize_currency(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_currency(_), do: nil

  defp non_neg_int(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_), do: 0

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp provider_reference_update_needed?(payment_intent, attrs) do
    Enum.any?(
      [
        :provider_payment_id,
        :provider_session_id,
        :provider_customer_ref,
        :provider_payment_method_ref,
        :provider_client_secret
      ],
      fn key ->
        Map.get(attrs, key) != nil and Map.get(payment_intent, key) != Map.get(attrs, key)
      end
    )
  end
end
