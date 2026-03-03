defmodule Store.Workers.ProcessWebhookReceiptWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.Repo

  import Ash.Expr
  require Ash.Query

  alias Store.Comms.EmailOutbox
  alias Store.Orders.{Order, PaymentApplication}
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.TestFixtures
  alias Store.Workers.ProcessWebhookReceiptWorker

  test "worker performs apply-once payment success transition and order effects" do
    order = create_order!()
    payment_intent = create_submitted_payment_intent!(order.id)

    raw_body =
      Jason.encode!(%{
        "id" => "evt_worker_payment_success_001",
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

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          provider_event_id: "evt_worker_payment_success_001",
          event_type: "payment_intent.succeeded",
          verification_status: "verified",
          processing_status: "new",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
    assert :paid == fetch_order!(order.id).state

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert 1 ==
             PaymentApplication
             |> Ash.Query.filter(expr(order_id == ^order.id))
             |> Ash.count!(domain: Store.Orders, authorize?: false)

    assert 1 ==
             EmailOutbox
             |> Ash.Query.filter(expr(order_id == ^order.id and template_kind == :order_receipt))
             |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
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

  defp create_order! do
    user =
      TestFixtures.register_user!(email: TestFixtures.unique_email("phase23_worker_receipt_user"))

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{user_id: user.id})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    order
    |> Ash.Changeset.for_update(
      :finalize_checkout_totals,
      %{
        currency_code: "USD",
        grand_total_minor: 0,
        items_subtotal_minor: 0,
        shipping_total_minor: 0
      },
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
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
