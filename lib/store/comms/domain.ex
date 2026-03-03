defmodule Store.Comms do
  @moduledoc """
  Outbound communications domain for transactional email delivery.
  """

  import Ash.Expr

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Accounts.User
  alias Store.Comms.{EmailOutbox, Providers, Templates}
  alias Store.Orders.Order
  alias Store.Payments.Refund
  alias Store.Repo
  alias Store.Workers.DeliverEmailOutboxWorker

  use Ash.Domain

  @stale_processing_timeout_seconds 15 * 60

  resources do
    resource(Store.Comms.EmailOutbox)
  end

  @spec enqueue_order_receipt_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_order_receipt_for_system(order_id, opts \\ []) when is_binary(order_id) do
    with {:ok, order} <- fetch_order(order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: nil,
             template_kind: :order_receipt,
             to_email: to_email,
             subject: "Order receipt #{order.order_ref}",
             idempotency_key: "order_receipt:order:#{order.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "amount_minor" => order.grand_total_minor || 0,
               "currency" => order.currency_code || "USD"
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_refund_requested_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_refund_requested_for_system(refund_id, opts \\ []) when is_binary(refund_id) do
    with {:ok, refund} <- fetch_refund(refund_id),
         {:ok, order} <- fetch_order(refund.order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: refund.id,
             template_kind: :refund_requested,
             to_email: to_email,
             subject: "Refund requested for order #{order.order_ref}",
             idempotency_key: "refund_requested:refund:#{refund.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "refund_id" => refund.id,
               "amount_minor" => refund.requested_amount_minor,
               "currency" => refund.currency
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec enqueue_refund_processed_for_system(String.t(), keyword()) ::
          {:ok, EmailOutbox.t()} | {:error, term()}
  def enqueue_refund_processed_for_system(refund_id, opts \\ []) when is_binary(refund_id) do
    with {:ok, refund} <- fetch_refund(refund_id),
         {:ok, order} <- fetch_order(refund.order_id),
         {:ok, to_email} <- resolve_recipient_email(order, opts),
         {:ok, provider} <- resolve_provider(opts),
         {:ok, outbox} <-
           upsert_outbox(%{
             order_id: order.id,
             refund_id: refund.id,
             template_kind: :refund_processed,
             to_email: to_email,
             subject: "Refund processed for order #{order.order_ref}",
             idempotency_key: "refund_processed:refund:#{refund.id}",
             provider: provider,
             template_assigns: %{
               "order_id" => order.id,
               "order_ref" => order.order_ref,
               "refund_id" => refund.id,
               "amount_minor" => refund.requested_amount_minor,
               "currency" => refund.currency
             }
           }),
         {:ok, _job} <- enqueue_delivery_job(outbox.id) do
      emit_outbox_insert_telemetry(outbox)
      {:ok, outbox}
    end
  end

  @spec deliver_outbox_email_for_system(String.t()) :: :ok | {:error, term()} | {:discard, term()}
  def deliver_outbox_email_for_system(outbox_id) when is_binary(outbox_id) do
    started_at = System.monotonic_time()

    with {:ok, :claimed} <- claim_for_delivery(outbox_id),
         {:ok, outbox} <- fetch_outbox(outbox_id),
         {:ok, message} <- Templates.build_message_for_delivery(outbox),
         result <- Providers.deliver_email(outbox.provider, message),
         :ok <- handle_delivery_result(outbox, result, started_at) do
      :ok
    else
      {:discard, reason} ->
        {:discard, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reclaim_stale_processing_for_system(keyword()) ::
          {:ok, %{reclaimed_count: non_neg_integer(), outbox_ids: [String.t()]}}
          | {:error, term()}
  def reclaim_stale_processing_for_system(opts \\ []) when is_list(opts) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @stale_processing_timeout_seconds)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_before = DateTime.add(now, -timeout_seconds, :second)

    query = """
    UPDATE email_outboxes
    SET state = 'pending',
        processing_started_at = NULL,
        last_error = COALESCE(last_error, 'processing_timeout_reclaimed'),
        updated_at = $2
    WHERE state = 'processing'
      AND processing_started_at IS NOT NULL
      AND processing_started_at < $1
    RETURNING id::text
    """

    case SQL.query(Repo, query, [stale_before, now]) do
      {:ok, %{rows: rows}} ->
        outbox_ids = Enum.map(rows, fn [id] -> id end)
        Enum.each(outbox_ids, &maybe_enqueue_delivery_job/1)
        {:ok, %{reclaimed_count: length(outbox_ids), outbox_ids: outbox_ids}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_provider(opts) do
    provider_opt = Keyword.get(opts, :provider)
    Providers.normalize_provider(provider_opt || Providers.default_provider())
  end

  defp upsert_outbox(attrs) when is_map(attrs) do
    attrs =
      Map.merge(
        %{
          body_text: "",
          body_html: nil,
          attempt_count: 0,
          state: :pending
        },
        attrs
      )

    EmailOutbox
    |> Ash.Changeset.for_create(:enqueue, attrs, context: %{system?: true})
    |> Ash.create(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp fetch_order(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:error, {:order_not_found, order_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_refund(refund_id) do
    query = Refund |> Ash.Query.filter(expr(id == ^refund_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, [refund | _]} -> {:ok, refund}
      {:ok, []} -> {:error, {:refund_not_found, refund_id}}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_recipient_email(order, opts) do
    case Keyword.get(opts, :to_email) do
      to_email when is_binary(to_email) and to_email != "" ->
        {:ok, String.trim(to_email)}

      _ ->
        resolve_order_user_email(order, opts)
    end
  end

  defp resolve_order_user_email(order, opts) do
    user_id = order.user_id || Keyword.get(opts, :order_user_id)

    case user_id do
      user_id when is_binary(user_id) ->
        fetch_user_email(user_id)

      _ ->
        {:error, :missing_order_recipient}
    end
  end

  defp fetch_user_email(user_id) do
    query = User |> Ash.Query.filter(expr(id == ^user_id))

    case Ash.read(query, domain: Store.Accounts, authorize?: false, context: %{system?: true}) do
      {:ok, [%User{email: email} | _]} ->
        normalize_user_email(email)

      {:ok, [_ | _]} ->
        {:error, :missing_order_recipient}

      {:ok, []} ->
        {:error, :missing_order_recipient}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_user_email(email) when is_binary(email) and email != "", do: {:ok, email}

  defp normalize_user_email(email) do
    email = to_string(email)

    if email != "" do
      {:ok, email}
    else
      {:error, :missing_order_recipient}
    end
  end

  defp enqueue_delivery_job(outbox_id) do
    %{"email_outbox_id" => outbox_id}
    |> DeliverEmailOutboxWorker.new()
    |> Oban.insert()
  end

  defp maybe_enqueue_delivery_job(outbox_id) do
    case enqueue_delivery_job(outbox_id) do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp fetch_outbox(outbox_id) do
    case EmailOutbox.get_for_system(outbox_id, context: %{system?: true}, authorize?: false) do
      {:ok, %EmailOutbox{} = outbox} -> {:ok, outbox}
      {:ok, nil} -> {:discard, :outbox_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp claim_for_delivery(outbox_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_before = DateTime.add(now, -@stale_processing_timeout_seconds, :second)

    claim_query = """
    UPDATE email_outboxes
    SET state = 'processing',
        attempt_count = attempt_count + 1,
        processing_started_at = $2,
        last_error = NULL,
        updated_at = $2
    WHERE id = $1::text::uuid
      AND (
        state = 'pending'
        OR (
          state = 'processing'
          AND processing_started_at IS NOT NULL
          AND processing_started_at < $3
        )
      )
    RETURNING id::text
    """

    case SQL.query(Repo, claim_query, [outbox_id, now, stale_before]) do
      {:ok, %{rows: [[_id]]}} ->
        {:ok, :claimed}

      {:ok, %{rows: []}} ->
        normalize_unclaimed_outbox(outbox_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_unclaimed_outbox(outbox_id) do
    with {:ok, outbox} <- fetch_outbox(outbox_id) do
      case outbox.state do
        :sent -> {:discard, :already_sent}
        :processing -> {:discard, :already_processing}
        :failed -> {:discard, :already_failed}
        _ -> {:discard, :not_claimable}
      end
    end
  end

  defp handle_delivery_result(outbox, {:ok, provider_message_id}, started_at) do
    outbox
    |> Ash.Changeset.for_update(
      :mark_sent,
      %{
        provider_message_id: provider_message_id,
        sent_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      },
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _updated} ->
        emit_delivery_attempt_telemetry(outbox, :sent, started_at)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_delivery_result(outbox, {:error, :transient, reason}, started_at) do
    with {:ok, _updated} <- mark_pending_retry(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :transient_error, started_at)
      {:error, reason}
    end
  end

  defp handle_delivery_result(outbox, {:error, :permanent, reason}, started_at) do
    with {:ok, _updated} <- mark_failed(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :permanent_error, started_at)
      {:discard, inspect(reason)}
    end
  end

  defp handle_delivery_result(outbox, {:error, reason}, started_at) do
    with {:ok, _updated} <- mark_pending_retry(outbox, reason) do
      emit_delivery_attempt_telemetry(outbox, :transient_error, started_at)
      {:error, reason}
    end
  end

  defp mark_pending_retry(outbox, reason) do
    message = inspect(reason)

    outbox
    |> Ash.Changeset.for_update(
      :mark_pending_retry,
      %{last_error: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp mark_failed(outbox, reason) do
    message = inspect(reason)

    outbox
    |> Ash.Changeset.for_update(
      :mark_failed,
      %{last_error: message},
      context: %{system?: true}
    )
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp emit_outbox_insert_telemetry(outbox) do
    :telemetry.execute(
      [:store, :comms, :outbox_insert],
      %{count: 1},
      %{kind: outbox.template_kind, provider: outbox.provider}
    )
  end

  defp emit_delivery_attempt_telemetry(outbox, outcome, started_at) do
    :telemetry.execute(
      [:store, :comms, :delivery_attempt],
      %{duration: System.monotonic_time() - started_at},
      %{provider: outbox.provider, template: outbox.template_kind, outcome: outcome}
    )
  end
end
