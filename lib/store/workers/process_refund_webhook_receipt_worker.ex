defmodule Store.Workers.ProcessRefundWebhookReceiptWorker do
  @moduledoc false

  use Oban.Worker, queue: :refunds, max_attempts: 10

  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.WebhookReceipt

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_receipt_id" => webhook_receipt_id}})
      when is_binary(webhook_receipt_id) do
    with {:ok, receipt} <- fetch_webhook_receipt(webhook_receipt_id),
         result <- PaymentsFacade.process_refund_webhook_receipt_for_system(receipt),
         :ok <- normalize_result(result) do
      :ok
    else
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing webhook_receipt_id"}

  defp fetch_webhook_receipt(webhook_receipt_id) do
    case PaymentsFacade.get_webhook_receipt_for_system(webhook_receipt_id) do
      {:ok, %WebhookReceipt{} = receipt} -> {:ok, receipt}
      {:ok, nil} -> {:discard, "webhook receipt not found"}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:discard, reason}), do: {:discard, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}
end
