defmodule StoreWeb.WebhookController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Payments.WebhookReceipt
  alias Store.Support.Errors.Error
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker
  alias StoreWeb.API.ErrorResponder

  @max_body_length 8_000_000
  @read_length 1_000_000
  @read_timeout 15_000

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"provider" => provider}) when is_binary(provider) do
    with {:ok, raw_body, conn} <- extract_raw_body(conn),
         headers <- headers_to_map(conn.req_headers),
         {:ok, receipt} <- ingest_receipt(provider, raw_body, headers),
         {:ok, _job} <- enqueue_processing_job(receipt.id, raw_body) do
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
        read_raw_body(conn)
    end
  end

  defp ingest_receipt(provider, raw_body, headers) do
    attrs = %{
      provider: provider,
      raw_body: raw_body,
      headers: headers
    }

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.create(domain: Store.Payments, authorize?: false)
  end

  defp enqueue_processing_job(webhook_receipt_id, raw_body) do
    worker = processing_worker(raw_body)

    %{"webhook_receipt_id" => webhook_receipt_id}
    |> worker.new()
    |> Oban.insert()
  end

  defp processing_worker(raw_body) do
    if refund_event_payload?(raw_body) do
      ProcessRefundWebhookReceiptWorker
    else
      ProcessWebhookReceiptWorker
    end
  end

  defp refund_event_payload?(raw_body) when is_binary(raw_body) do
    with {:ok, payload} <- Jason.decode(raw_body),
         event_type when is_binary(event_type) <-
           Map.get(payload, "event_type") || Map.get(payload, "type") do
      String.starts_with?(event_type, "refund.") or event_type == "charge.refunded"
    else
      _ -> false
    end
  end

  defp refund_event_payload?(_raw_body), do: false

  defp headers_to_map(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn values -> [value | values] end)
    end)
    |> Enum.into(%{}, fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  defp read_raw_body(conn, acc \\ "")

  defp read_raw_body(conn, acc) do
    case read_body(conn,
           length: @max_body_length,
           read_length: @read_length,
           read_timeout: @read_timeout
         ) do
      {:ok, body, conn} ->
        {:ok, acc <> body, conn}

      {:more, chunk, conn} ->
        read_raw_body(conn, acc <> chunk)

      {:error, _reason} ->
        {:discard, "unable to read webhook body"}
    end
  end
end
