defmodule Store.Payments.Facade do
  @moduledoc """
  Consumer and system-scoped surfaces for payment intents and webhook receipts.
  """

  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
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
          {:ok, WebhookReceipt.t()} | {:error, term()}
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
    with {:ok, processing_receipt} <- mark_processing(receipt),
         result <-
           Store.Payments.process_payment_webhook_receipt(processing_receipt,
             context: %{system?: true}
           ),
         :ok <- mark_terminal_status(processing_receipt, result) do
      result
    else
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  @spec process_refund_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    with {:ok, processing_receipt} <- mark_processing(receipt),
         result <-
           Store.Payments.process_refund_webhook_receipt(processing_receipt,
             context: %{system?: true}
           ),
         :ok <- mark_terminal_status(processing_receipt, result) do
      result
    else
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
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
end
