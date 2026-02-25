defmodule Store.Payments do
  @moduledoc """
  Payments domain for payment lifecycle, provider events, and refunds.
  """

  use Ash.Domain

  alias Store.Payments.Refunds

  resources do
    resource(Store.Payments.PaymentIntent)
    resource(Store.Payments.ProviderEvent)
    resource(Store.Payments.Refund)
    resource(Store.Payments.RefundAttempt)
    resource(Store.Payments.WebhookReceipt)
  end

  @spec request_refund(map(), keyword()) :: {:ok, Store.Payments.Refund.t()} | {:error, term()}
  def request_refund(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Refunds.request_refund(attrs, opts)
  end

  @spec process_refund_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Refunds.process_refund_webhook_receipt(receipt, opts)
  end
end
