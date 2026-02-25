defmodule StoreWeb.WebhookControllerTest do
  use StoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Store.Repo

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker

  test "controller stores raw receipt, enqueues worker, and leaves transition to worker", %{
    conn: conn
  } do
    payment_intent = create_submitted_payment_intent!()
    raw_body = Jason.encode!(%{"payment_intent_id" => payment_intent.id})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"data" => %{"webhook_receipt_id" => webhook_receipt_id}} = json_response(conn, 202)

    assert_enqueued(
      worker: ProcessWebhookReceiptWorker,
      args: %{"webhook_receipt_id" => webhook_receipt_id},
      queue: "webhooks"
    )

    assert {:ok, [receipt]} =
             WebhookReceipt
             |> Ash.Query.filter(expr(id == ^webhook_receipt_id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    assert receipt.raw_body == raw_body
    assert get_in(receipt.headers, ["content-type"]) == ["application/json"]

    assert :submitted == fetch_payment_intent!(payment_intent.id).state
  end

  test "duplicate payload ingest is idempotent and reuses receipt record", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = Jason.encode!(%{"payment_intent_id" => payment_intent.id})
    expected_key = sha256_hex("stripe\n" <> raw_body)

    conn1 =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    conn2 =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    receipt_id_1 = json_response(conn1, 202)["data"]["webhook_receipt_id"]
    receipt_id_2 = json_response(conn2, 202)["data"]["webhook_receipt_id"]

    assert receipt_id_1 == receipt_id_2

    count =
      WebhookReceipt
      |> Ash.Query.filter(expr(idempotency_key == ^expected_key))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "refund event payload routes to dedicated refund worker", %{conn: conn} do
    raw_body =
      Jason.encode!(%{
        "event_type" => "refund.succeeded",
        "provider_event_id" => "evt_refund_route_001",
        "refund" => %{"idempotency_key" => "refund:route:test"}
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"data" => %{"webhook_receipt_id" => webhook_receipt_id}} = json_response(conn, 202)

    assert_enqueued(
      worker: ProcessRefundWebhookReceiptWorker,
      args: %{"webhook_receipt_id" => webhook_receipt_id},
      queue: "refunds"
    )
  end

  defp create_submitted_payment_intent! do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
