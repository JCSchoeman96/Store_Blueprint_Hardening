defmodule Store.Workers.ProcessWebhookReceiptWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.Repo

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Workers.ProcessWebhookReceiptWorker

  test "worker performs PaymentIntent submitted -> succeeded transition" do
    payment_intent = create_submitted_payment_intent!()
    raw_body = Jason.encode!(%{"payment_intent_id" => payment_intent.id})

    receipt =
      WebhookReceipt
      |> Ash.Changeset.for_create(
        :ingest,
        %{
          provider: "stripe",
          raw_body: raw_body,
          headers: %{"content-type" => ["application/json"]}
        }
      )
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    assert :ok =
             perform_job(ProcessWebhookReceiptWorker, %{"webhook_receipt_id" => receipt.id})

    assert :succeeded == fetch_payment_intent!(payment_intent.id).state
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
end
