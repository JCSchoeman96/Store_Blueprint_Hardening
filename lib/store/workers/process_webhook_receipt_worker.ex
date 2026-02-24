defmodule Store.Workers.ProcessWebhookReceiptWorker do
  @moduledoc false

  use Oban.Worker, queue: :webhooks, max_attempts: 10

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_receipt_id" => webhook_receipt_id}})
      when is_binary(webhook_receipt_id) do
    with {:ok, receipt} <- fetch_webhook_receipt(webhook_receipt_id),
         {:ok, payment_intent_id} <- extract_payment_intent_id(receipt.raw_body),
         {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id),
         :ok <- maybe_mark_succeeded(payment_intent) do
      :ok
    else
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing webhook_receipt_id"}

  defp fetch_webhook_receipt(webhook_receipt_id) do
    query =
      WebhookReceipt
      |> Ash.Query.filter(expr(id == ^webhook_receipt_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [receipt | _]} -> {:ok, receipt}
      {:ok, []} -> {:discard, "webhook receipt not found"}
      {:error, error} -> {:error, error}
    end
  end

  defp extract_payment_intent_id(raw_body) when is_binary(raw_body) do
    with {:ok, payload} <- Jason.decode(raw_body),
         payment_intent_id when is_binary(payment_intent_id) <-
           Map.get(payload, "payment_intent_id") do
      {:ok, payment_intent_id}
    else
      _ -> {:discard, "missing payment_intent_id in webhook payload"}
    end
  end

  defp extract_payment_intent_id(_raw_body), do: {:discard, "invalid webhook payload"}

  defp fetch_payment_intent(payment_intent_id) do
    query =
      PaymentIntent
      |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [payment_intent | _]} -> {:ok, payment_intent}
      {:ok, []} -> {:discard, "payment intent not found"}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_succeeded(%PaymentIntent{state: :succeeded}), do: :ok

  defp maybe_mark_succeeded(%PaymentIntent{state: :submitted} = payment_intent) do
    payment_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Payments, context: %{system?: true}, authorize?: false)
    |> case do
      {:ok, _updated} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_succeeded(%PaymentIntent{state: state}) do
    {:discard, "payment intent state #{state} is not transitionable"}
  end
end
