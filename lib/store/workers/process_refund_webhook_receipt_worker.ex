defmodule Store.Workers.ProcessRefundWebhookReceiptWorker do
  @moduledoc false

  import Ash.Expr
  require Ash.Query

  use Oban.Worker, queue: :refunds, max_attempts: 10

  alias Store.Payments.WebhookReceipt

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_receipt_id" => webhook_receipt_id}})
      when is_binary(webhook_receipt_id) do
    with {:ok, receipt} <- fetch_webhook_receipt(webhook_receipt_id),
         result <- Store.Payments.process_refund_webhook_receipt(receipt),
         :ok <- normalize_result(result) do
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

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:discard, reason}), do: {:discard, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}
end
