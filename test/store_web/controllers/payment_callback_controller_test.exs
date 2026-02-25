defmodule StoreWeb.PaymentCallbackControllerTest do
  use StoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Store.Repo

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessWebhookReceiptWorker

  test "callback controller stores receipt, enqueues payment webhook worker, and is enqueue-only",
       %{
         conn: conn
       } do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    raw_body = Jason.encode!(%{"payment_intent_id" => payment_intent.id})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/payments/stripe/callback", raw_body)

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
    assert :submitted == fetch_payment_intent!(payment_intent.id).state
    assert :pending_payment == fetch_order!(order.id).state
  end

  defp create_order! do
    Order
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_submitted_payment_intent!(order_id) do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{order_id: order_id})
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    payment_intent
    |> Ash.Changeset.for_update(:submit, %{})
    |> Ash.update!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp fetch_payment_intent!(id) do
    assert {:ok, [payment_intent]} =
             PaymentIntent
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    payment_intent
  end
end
