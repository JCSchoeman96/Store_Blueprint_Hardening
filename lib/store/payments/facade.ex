defmodule Store.Payments.Facade do
  @moduledoc """
  Consumer and system-scoped surfaces for payment intents and webhook receipts.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.AuditLog
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.{PaymentIntent, Providers, WebhookReceipt}
  alias Store.Payments.Queries.{PaymentIntentIndexQuery, PaymentIntentShowQuery}
  alias Store.Support.Errors.Normalize

  @spec list_payment_intents_for_admin(map(), PaymentIntentIndexQuery.t()) ::
          {:ok, [PaymentIntent.t()]} | {:error, term()}
  def list_payment_intents_for_admin(actor, %PaymentIntentIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      PaymentIntent
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Store.Payments, actor: actor) do
      {:ok, intents} -> {:ok, intents}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_payment_intent_for_admin(map(), PaymentIntentShowQuery.t()) ::
          {:ok, PaymentIntent.t() | nil} | {:error, term()}
  def get_payment_intent_for_admin(actor, %PaymentIntentShowQuery{id: id}) when is_map(actor) do
    ash_query = Ash.Query.for_read(PaymentIntent, :get_for_admin, %{id: id}, actor: actor)

    case Ash.read_one(ash_query, domain: Store.Payments, actor: actor) do
      {:ok, intent} -> {:ok, intent}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec ingest_webhook_receipt_for_system(WebhookReceiptIngestInput.t()) ::
          {:ok, %{receipt: WebhookReceipt.t(), duplicate?: boolean()}} | {:error, term()}
  def ingest_webhook_receipt_for_system(%WebhookReceiptIngestInput{} = input) do
    attrs =
      input
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.create(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> normalize_result()
  end

  @spec get_webhook_receipt_for_system(Ecto.UUID.t()) ::
          {:ok, WebhookReceipt.t() | nil} | {:error, term()}
  def get_webhook_receipt_for_system(webhook_receipt_id) when is_binary(webhook_receipt_id) do
    case WebhookReceipt.get_for_system(webhook_receipt_id,
           context: %{system?: true},
           authorize?: false
         ) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec process_payment_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    started_at = System.monotonic_time()

    case mark_processing(receipt) do
      {:ok, processing_receipt} ->
        result =
          with :ok <- Providers.ensure_enabled_provider(processing_receipt.provider) do
            Store.Payments.process_payment_webhook_receipt(processing_receipt,
              context: %{system?: true}
            )
          end

        case mark_terminal_status(processing_receipt, result) do
          :ok ->
            emit_webhook_processed_telemetry(
              :webhook_processed,
              processing_receipt,
              result,
              started_at
            )

            result

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  @spec process_refund_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    started_at = System.monotonic_time()

    case mark_processing(receipt) do
      {:ok, processing_receipt} ->
        result =
          with :ok <- Providers.ensure_enabled_provider(processing_receipt.provider) do
            Store.Payments.process_refund_webhook_receipt(processing_receipt,
              context: %{system?: true}
            )
          end

        case mark_terminal_status(processing_receipt, result) do
          :ok ->
            emit_webhook_processed_telemetry(
              :refund_webhook_processed,
              processing_receipt,
              result,
              started_at
            )

            result

          {:error, reason} ->
            {:error, Normalize.normalize(reason)}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  @spec purge_expired_webhook_evidence_for_system(keyword()) ::
          {:ok, %{purged_count: non_neg_integer(), receipt_ids: [Ecto.UUID.t()]}}
          | {:error, term()}
  def purge_expired_webhook_evidence_for_system(opts \\ []) when is_list(opts) do
    retention_days =
      opts
      |> Keyword.get(
        :retention_days,
        Application.get_env(:store, :operations, []) |> Keyword.get(:webhook_retention_days, 30)
      )

    limit = Keyword.get(opts, :limit, 100)

    cutoff =
      DateTime.utc_now() |> DateTime.add(-retention_days, :day) |> DateTime.truncate(:microsecond)

    query =
      WebhookReceipt
      |> Ash.Query.filter(expr(received_at < ^cutoff and is_nil(evidence_purged_at)))
      |> Ash.Query.sort(received_at: :asc, id: :asc)
      |> Ash.Query.limit(limit)

    with {:ok, receipts} <-
           Ash.read(query, domain: Store.Payments, authorize?: false, context: %{system?: true}),
         {:ok, purged_ids} <- purge_receipts(receipts) do
      :ok = maybe_audit_purge(purged_ids, cutoff)
      {:ok, %{purged_count: length(purged_ids), receipt_ids: purged_ids}}
    else
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  defp normalize_result({:ok, %WebhookReceipt{} = receipt}) do
    {:ok,
     %{
       receipt: receipt,
       duplicate?: Ash.Resource.get_metadata(receipt, :upsert_skipped) == true
     }}
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp mark_processing(%WebhookReceipt{processing_status: "processed"} = receipt),
    do: {:ok, receipt}

  defp mark_processing(%WebhookReceipt{} = receipt) do
    receipt
    |> Ash.Changeset.for_update(:mark_processing, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
  end

  defp mark_terminal_status(receipt, :ok), do: mark_processed(receipt)
  defp mark_terminal_status(receipt, {:discard, _reason}), do: mark_processed(receipt)

  defp mark_terminal_status(receipt, {:error, reason}) do
    normalized = Normalize.normalize(reason)
    mark_failed(receipt, normalized)
  end

  defp mark_processed(%WebhookReceipt{} = receipt) do
    receipt
    |> Ash.Changeset.for_update(
      :mark_processed,
      %{processed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)},
      context: %{system?: true}
    )
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> case do
      {:ok, _receipt} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mark_failed(%WebhookReceipt{} = receipt, normalized_error) do
    attrs = %{
      error_code: normalized_error.code,
      error_detail: normalized_error.message,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    receipt
    |> Ash.Changeset.for_update(:mark_failed, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> case do
      {:ok, _receipt} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp purge_receipts(receipts) do
    purged_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    receipts
    |> Enum.reduce_while({:ok, []}, fn receipt, {:ok, acc} ->
      attrs = %{raw_body: "[PURGED]", headers: %{}, evidence_purged_at: purged_at}

      case receipt
           |> Ash.Changeset.for_update(:purge_evidence, attrs, context: %{system?: true})
           |> Ash.update(domain: Store.Payments, authorize?: false, context: %{system?: true}) do
        {:ok, _updated} -> {:cont, {:ok, [receipt.id | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, purged_ids} -> {:ok, Enum.reverse(purged_ids)}
      other -> other
    end
  end

  defp maybe_audit_purge([], _cutoff), do: :ok

  defp maybe_audit_purge(receipt_ids, cutoff) do
    AuditLog
    |> Ash.Changeset.for_create(
      :create,
      %{
        action: "WEBHOOK_EVIDENCE_PURGED",
        resource: "webhook_receipts",
        meta: %{
          purged_count: length(receipt_ids),
          receipt_ids: Enum.take(receipt_ids, 20),
          cutoff: DateTime.to_iso8601(cutoff)
        }
      },
      context: %{system?: true}
    )
    |> Ash.create(domain: Store.Admin, authorize?: false, context: %{system?: true})
    |> case do
      {:ok, _audit_log} -> :ok
      {:error, _error} -> :ok
    end
  end

  defp emit_webhook_processed_telemetry(
         name,
         receipt,
         result,
         started_at,
         fallback_outcome \\ nil
       ) do
    :telemetry.execute(
      [:store, :payments, name],
      %{duration: System.monotonic_time() - started_at},
      %{
        provider: receipt.provider,
        outcome: webhook_outcome(result, fallback_outcome)
      }
    )
  end

  defp webhook_outcome({:ok, _value}, _fallback), do: :ok
  defp webhook_outcome(:ok, _fallback), do: :ok
  defp webhook_outcome({:discard, _reason}, _fallback), do: :discard
  defp webhook_outcome({:error, _reason}, _fallback), do: :error
  defp webhook_outcome(_result, fallback) when not is_nil(fallback), do: fallback
  defp webhook_outcome(_result, _fallback), do: :unknown
end
