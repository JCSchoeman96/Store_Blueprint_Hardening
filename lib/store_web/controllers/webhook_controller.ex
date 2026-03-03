defmodule StoreWeb.WebhookController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Payments.Facade, as: PaymentsFacade
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Providers
  alias Store.Support.Errors.Error
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker
  alias StoreWeb.API.ErrorResponder

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider" => provider}) when is_binary(provider) do
    with {:ok, raw_body, conn} <- extract_raw_body(conn),
         headers <- headers_to_map(conn.req_headers),
         normalized_provider = provider_name(provider),
         {:ok, payload} <- Providers.verify_webhook(normalized_provider, headers, raw_body, []),
         {:ok, canonical_receipt} <- Providers.normalize_webhook(normalized_provider, payload),
         {:ok, receipt} <-
           ingest_receipt(normalized_provider, raw_body, headers, canonical_receipt),
         {:ok, _job} <- enqueue_processing_job(receipt.id, canonical_receipt.event_type) do
      conn
      |> put_status(:accepted)
      |> json(%{data: %{webhook_receipt_id: receipt.id}})
    else
      {:error, error} ->
        ErrorResponder.render(conn, error)

      {:discard, reason} ->
        ErrorResponder.render(conn, Error.new("VALIDATION_ERROR", reason))
    end
  end

  def create(conn, _params) do
    ErrorResponder.render(conn, Error.new("VALIDATION_ERROR", "provider is required"))
  end

  defp extract_raw_body(conn) do
    case conn.assigns[:raw_body] do
      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}

      _ ->
        {:error,
         Error.new(
           "PAYMENT_PAYLOAD_INVALID",
           "raw webhook body was not captured; ensure Plug.Parsers body_reader is configured"
         )}
    end
  end

  defp ingest_receipt(provider, raw_body, headers, canonical_receipt) do
    idempotency_key =
      canonical_receipt.provider_idempotency_key ||
        "#{provider}:#{canonical_receipt.provider_event_id}"

    with {:ok, input} <-
           WebhookReceiptIngestInput.new(%{
             provider: provider,
             idempotency_key: idempotency_key,
             payload_sha256: sha256_hex(raw_body),
             verification_status: "verified",
             processing_status: "new",
             provider_event_id: canonical_receipt.provider_event_id,
             event_type: canonical_receipt.event_type,
             verified_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
             raw_body: raw_body,
             headers: headers
           }) do
      PaymentsFacade.ingest_webhook_receipt_for_system(input)
    end
  end

  defp enqueue_processing_job(webhook_receipt_id, event_type) do
    worker = processing_worker(event_type)

    %{"webhook_receipt_id" => webhook_receipt_id}
    |> worker.new()
    |> Oban.insert()
  end

  defp processing_worker(event_type) when is_binary(event_type) do
    if refund_event_type?(event_type) do
      ProcessRefundWebhookReceiptWorker
    else
      ProcessWebhookReceiptWorker
    end
  end

  defp processing_worker(_event_type), do: ProcessWebhookReceiptWorker

  defp refund_event_type?(event_type) do
    String.starts_with?(event_type, "refund.") or event_type == "charge.refunded"
  end

  defp headers_to_map(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn values -> [value | values] end)
    end)
    |> Enum.into(%{}, fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  defp provider_name(provider) do
    provider
    |> Providers.normalize_provider()
    |> Atom.to_string()
  end

  defp sha256_hex(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
