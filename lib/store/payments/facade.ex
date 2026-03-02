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
    Store.Payments.process_payment_webhook_receipt(receipt, context: %{system?: true})
  end

  @spec process_refund_webhook_receipt_for_system(WebhookReceipt.t()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt_for_system(%WebhookReceipt{} = receipt) do
    Store.Payments.process_refund_webhook_receipt(receipt, context: %{system?: true})
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}
end
