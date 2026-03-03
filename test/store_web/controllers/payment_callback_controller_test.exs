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
    raw_body = stripe_payment_event_raw_body(payment_intent)
    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
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

  test "callback rejects missing stripe signature", %{conn: conn} do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_callback_missing_sig")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/payments/stripe/callback", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_MISSING"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
  end

  test "callback signature verification is bound to raw body bytes", %{conn: conn} do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    compact_raw_body = stripe_payment_event_raw_body(payment_intent, "evt_callback_raw_bytes")
    modified_raw_body = Jason.encode!(Jason.decode!(compact_raw_body), pretty: true)
    signature_for_compact = stripe_signature(compact_raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature_for_compact)
      |> post(~p"/api/payments/stripe/callback", modified_raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
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

  defp stripe_payment_event_raw_body(payment_intent, event_id \\ "evt_callback_001") do
    Jason.encode!(%{
      "id" => event_id,
      "type" => "payment_intent.succeeded",
      "data" => %{
        "object" => %{
          "id" => payment_intent.id,
          "amount_received" => payment_intent.amount_received_minor,
          "currency" => String.downcase(payment_intent.currency || "USD"),
          "metadata" => %{}
        }
      }
    })
  end

  defp stripe_signature(raw_body, secret \\ nil) do
    secret = secret || stripe_webhook_secret()
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    payload = "#{timestamp}.#{raw_body}"

    signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp stripe_webhook_secret do
    :store
    |> Application.get_env(:payments, [])
    |> Keyword.get(:stripe, [])
    |> Keyword.fetch!(:webhook_secret)
  end
end
