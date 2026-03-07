defmodule StoreWeb.WebhookControllerTest do
  use StoreWeb.ConnCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessRefundWebhookReceiptWorker
  alias Store.Workers.ProcessWebhookReceiptWorker

  test "controller stores raw receipt, enqueues worker, and leaves transition to worker", %{
    conn: conn
  } do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent)
    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
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
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_payment_duplicate_001")
    signature = stripe_signature(raw_body)
    expected_key = "stripe:evt_payment_duplicate_001"

    conn1 =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    conn2 =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    receipt_id_1 = json_response(conn1, 202)["data"]["webhook_receipt_id"]
    receipt_id_2 = json_response(conn2, 202)["data"]["webhook_receipt_id"]

    assert receipt_id_1 == receipt_id_2

    assert [
             %Oban.Job{args: %{"webhook_receipt_id" => ^receipt_id_1}}
           ] =
             all_enqueued(
               worker: ProcessWebhookReceiptWorker,
               args: %{"webhook_receipt_id" => receipt_id_1}
             )

    count =
      WebhookReceipt
      |> Ash.Query.filter(expr(idempotency_key == ^expected_key))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert count == 1
  end

  test "successful webhook ingest emits persist, enqueue, and response telemetry", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_webhook_telemetry_001")
    signature = stripe_signature(raw_body)

    with_ingress_telemetry(fn ->
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> post(~p"/api/webhooks/stripe", raw_body)

      assert json_response(conn, 202)

      assert_receive {:telemetry, :persist, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :enqueue, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.provider == "stripe"
      assert metadata.result == :ok
      assert is_integer(measurements.query_count)

      assert_receive {:telemetry, :response, measurements, metadata}
      assert metadata.route == :webhook
      assert metadata.status_bucket == "2xx"
      assert metadata.result == :ok
      assert measurements.duration > 0
    end)
  end

  test "refund event payload routes to dedicated refund worker", %{conn: conn} do
    raw_body =
      Jason.encode!(%{
        "id" => "evt_refund_route_001",
        "type" => "refund.succeeded",
        "data" => %{
          "object" => %{
            "id" => "pi_refund_route_001",
            "amount" => 0,
            "currency" => "usd"
          }
        }
      })

    signature = stripe_signature(raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature)
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"data" => %{"webhook_receipt_id" => webhook_receipt_id}} = json_response(conn, 202)

    assert_enqueued(
      worker: ProcessRefundWebhookReceiptWorker,
      args: %{"webhook_receipt_id" => webhook_receipt_id},
      queue: "refunds"
    )
  end

  test "missing stripe signature is rejected", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_sig_missing_001")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_MISSING"}} = json_response(conn, 401)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == 0
  end

  test "invalid stripe signature is rejected", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()
    raw_body = stripe_payment_event_raw_body(payment_intent, "evt_sig_invalid_001")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=1,v1=bad")
      |> post(~p"/api/webhooks/stripe", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == 0
  end

  test "unknown provider is rejected before persistence", %{conn: conn} do
    raw_body = Jason.encode!(%{"id" => "evt_unknown_provider"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/webhooks/not-a-provider", raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_PROVIDER_UNSUPPORTED"}} = json_response(conn, 400)

    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
    assert webhook_receipt_count() == 0
  end

  test "signature verification uses exact raw body bytes", %{conn: conn} do
    payment_intent = create_submitted_payment_intent!()

    compact_raw_body = stripe_payment_event_raw_body(payment_intent, "evt_raw_bytes_001")

    modified_raw_body =
      Jason.encode!(Jason.decode!(compact_raw_body), pretty: true)

    signature_for_compact = stripe_signature(compact_raw_body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", signature_for_compact)
      |> post(~p"/api/webhooks/stripe", modified_raw_body)

    assert %{"errors" => %{"code" => "PAYMENT_SIGNATURE_INVALID"}} = json_response(conn, 401)
    refute_enqueued(worker: ProcessWebhookReceiptWorker)
    refute_enqueued(worker: ProcessRefundWebhookReceiptWorker)
  end

  defp create_submitted_payment_intent! do
    payment_intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{provider: :stripe})
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

  defp stripe_payment_event_raw_body(payment_intent, event_id \\ "evt_payment_webhook_001") do
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

  defp webhook_receipt_count do
    WebhookReceipt
    |> Ash.count!(domain: Store.Payments, authorize?: false)
  end

  defp with_ingress_telemetry(fun) when is_function(fun, 0) do
    parent = self()
    events = [:persist, :enqueue, :response]

    Enum.each(events, fn stage ->
      :telemetry.attach(
        {__MODULE__, stage, System.unique_integer([:positive])},
        [:store, :payments, :ingress, stage],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, stage, measurements, metadata})
        end,
        nil
      )
    end)

    try do
      fun.()
    after
      :telemetry.list_handlers([:store, :payments, :ingress, :persist])
      |> Enum.filter(&match?({__MODULE__, :persist, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

      :telemetry.list_handlers([:store, :payments, :ingress, :enqueue])
      |> Enum.filter(&match?({__MODULE__, :enqueue, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)

      :telemetry.list_handlers([:store, :payments, :ingress, :response])
      |> Enum.filter(&match?({__MODULE__, :response, _}, &1.id))
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
    end
  end
end
