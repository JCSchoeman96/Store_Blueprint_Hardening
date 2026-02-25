defmodule Store.Payments do
  @moduledoc """
  Payments domain for payment lifecycle, provider events, and refunds.
  """

  use Ash.Domain

  alias Store.Payments.{Interlocks, Refunds}

  resources do
    resource(Store.Payments.PaymentIntent)
    resource(Store.Payments.PaymentAttempt)
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

  @spec create_or_reuse_payment_intent(map(), keyword()) ::
          {:ok,
           %{
             payment_intent: Store.Payments.PaymentIntent.t(),
             payment_intent_key: String.t(),
             duplicate?: boolean()
           }}
          | {:error, term()}
  def create_or_reuse_payment_intent(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Interlocks.create_or_reuse_payment_intent(attrs, opts)
  end

  @spec process_payment_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Interlocks.process_payment_webhook_receipt(receipt, opts)
  end

  @spec apply_payment_success_once(Store.Payments.PaymentIntent.t() | String.t(), keyword()) ::
          {:ok,
           %{
             applied?: boolean(),
             order: Store.Orders.Order.t(),
             payment_intent: Store.Payments.PaymentIntent.t()
           }}
          | {:error, term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ []) when is_list(opts) do
    Interlocks.apply_payment_success_once(payment_intent_or_id, opts)
  end
end
