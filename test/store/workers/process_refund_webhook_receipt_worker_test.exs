defmodule Store.Workers.ProcessRefundWebhookReceiptWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.{PaymentIntent, Refund, RefundAttempt, WebhookReceipt}
  alias Store.Support.Errors.Error
  alias Store.Support.Time
  alias Store.TestFixtures
  alias Store.Workers.ProcessRefundWebhookReceiptWorker

  setup do
    previous = Application.get_env(:store, :payments, [])

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "worker is replay-safe and marks order refunded only at refundable threshold" do
    %{order: order, payment_intent: payment_intent} = create_refundable_order_fixture!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_refund_worker"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    context = %{step_up_at_mono_usec: Time.now_mono_usec()}

    assert {:ok, refund_a} =
             Store.Payments.request_refund(
               refund_request_attrs(order.id, payment_intent.id, 4000, "worker_refund_a"),
               actor: admin,
               context: context
             )

    assert {:ok, refund_b} =
             Store.Payments.request_refund(
               refund_request_attrs(order.id, payment_intent.id, 6000, "worker_refund_b"),
               actor: admin,
               context: context
             )

    assert 2 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(template_kind == :refund_requested and order_id == ^order.id)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    receipt_a =
      create_refund_webhook_receipt!(
        "stripe",
        %{
          "event_type" => "refund.succeeded",
          "provider_event_id" => "evt_refund_success_001",
          "refund" => %{
            "id" => "re_provider_001",
            "idempotency_key" => refund_a.idempotency_key
          }
        }
      )

    assert :ok =
             perform_job(ProcessRefundWebhookReceiptWorker, %{
               "webhook_receipt_id" => receipt_a.id
             })

    assert fetch_refund!(refund_a.id).state == :succeeded
    assert fetch_order!(order.id).state == :paid

    assert :ok =
             perform_job(ProcessRefundWebhookReceiptWorker, %{
               "webhook_receipt_id" => receipt_a.id
             })

    attempt_count =
      RefundAttempt
      |> Ash.Query.filter(expr(provider_event_key == "stripe:evt_refund_success_001"))
      |> Ash.count!(domain: Store.Payments, authorize?: false)

    assert attempt_count == 1

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(refund_id == ^refund_a.id and template_kind == :refund_processed)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    receipt_b =
      create_refund_webhook_receipt!(
        "stripe",
        %{
          "event_type" => "refund.succeeded",
          "provider_event_id" => "evt_refund_success_002",
          "refund" => %{
            "id" => "re_provider_002",
            "idempotency_key" => refund_b.idempotency_key
          }
        }
      )

    assert :ok =
             perform_job(ProcessRefundWebhookReceiptWorker, %{
               "webhook_receipt_id" => receipt_b.id
             })

    assert fetch_refund!(refund_b.id).state == :succeeded
    assert fetch_order!(order.id).state == :refunded

    assert 2 ==
             EmailOutbox
             |> Ash.Query.filter(
               expr(template_kind == :refund_processed and order_id == ^order.id)
             )
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  test "worker marks disabled provider receipts as failed without processing transitions" do
    Application.put_env(:store, :payments,
      enabled_providers: [],
      stripe: [webhook_secret: "whsec_test_only_change_me"]
    )

    receipt =
      create_refund_webhook_receipt!(
        :stripe,
        %{
          "event_type" => "refund.succeeded",
          "provider_event_id" => "evt_refund_disabled_001",
          "refund" => %{
            "id" => "re_disabled_001",
            "idempotency_key" => "refund_disabled_key"
          }
        }
      )

    assert {:error, %Error{code: "PAYMENT_PROVIDER_DISABLED"}} =
             perform_job(ProcessRefundWebhookReceiptWorker, %{
               "webhook_receipt_id" => receipt.id
             })

    updated_receipt = fetch_receipt!(receipt.id)
    assert updated_receipt.processing_status == "failed"
    assert updated_receipt.error_code == "PAYMENT_PROVIDER_DISABLED"
  end

  defp create_refundable_order_fixture! do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_refund_customer"))

    order = create_order!(customer.id)
    paid_order = mark_order_paid!(order)
    payment_intent = create_succeeded_payment_intent!(paid_order.id, 10_000, "USD")
    create_order_snapshot_line_item!(paid_order.id, 10_000, "USD")

    %{order: paid_order, payment_intent: payment_intent}
  end

  defp create_order!(user_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{order_ref: unique_order_ref(), user_id: user_id})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp mark_order_paid!(order) do
    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_succeeded_payment_intent!(order_id, amount_received_minor, currency) do
    intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order_id,
        amount_received_minor: amount_received_minor,
        currency: currency,
        provider: :stripe
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    submitted_intent =
      intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    submitted_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp create_order_snapshot_line_item!(order_id, net_line_total_minor, currency) do
    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      line_no: 1,
      currency: currency,
      quantity: 1,
      unit_price_minor: net_line_total_minor,
      line_total_minor: net_line_total_minor,
      sku_snapshot: "SKU-REFUND-WORKER-1",
      product_title_snapshot: "Refund Worker Product",
      variant_title_snapshot: "Default",
      discount_allocated_minor: 0,
      net_line_total_minor: net_line_total_minor
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_refund_webhook_receipt!(provider, payload) do
    WebhookReceipt
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: provider,
        raw_body: Jason.encode!(payload),
        headers: %{"content-type" => ["application/json"]}
      }
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_refund!(id) do
    assert {:ok, [refund]} =
             Refund
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    refund
  end

  defp fetch_order!(id) do
    assert {:ok, [order]} =
             Order
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Orders, authorize?: false)

    order
  end

  defp refund_request_attrs(order_id, payment_intent_id, amount_minor, reason) do
    %{
      order_id: order_id,
      payment_intent_id: payment_intent_id,
      requested_amount_minor: amount_minor,
      currency: "USD",
      provider: :stripe,
      reason: reason,
      line_item_ids: []
    }
  end

  defp unique_order_ref do
    "ORDRFNWRK#{System.unique_integer([:positive])}"
  end

  defp fetch_receipt!(id) do
    assert {:ok, [receipt]} =
             WebhookReceipt
             |> Ash.Query.filter(expr(id == ^id))
             |> Ash.read(domain: Store.Payments, authorize?: false)

    receipt
  end
end
