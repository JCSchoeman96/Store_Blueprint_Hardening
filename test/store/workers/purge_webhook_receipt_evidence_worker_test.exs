defmodule Store.Workers.PurgeWebhookReceiptEvidenceWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.AuditLog
  alias Store.Payments.WebhookReceipt
  alias Store.Workers.PurgeWebhookReceiptEvidenceWorker

  test "worker scrubs expired webhook evidence and preserves audit metadata" do
    old_receipt =
      create_receipt!(%{
        idempotency_key: "stripe:evt_old_001",
        provider_event_id: "evt_old_001",
        raw_body: ~s({"id":"evt_old_001"}),
        received_at:
          DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.truncate(:microsecond)
      })

    fresh_receipt =
      create_receipt!(%{
        idempotency_key: "stripe:evt_fresh_001",
        provider_event_id: "evt_fresh_001",
        raw_body: ~s({"id":"evt_fresh_001"}),
        received_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    assert :ok =
             perform_job(PurgeWebhookReceiptEvidenceWorker, %{
               "limit" => 50,
               "retention_days" => 1
             })

    purged_receipt = fetch_receipt!(old_receipt.id)
    untouched_receipt = fetch_receipt!(fresh_receipt.id)

    assert purged_receipt.raw_body == "[PURGED]"
    assert purged_receipt.headers == %{}
    assert %DateTime{} = purged_receipt.evidence_purged_at
    assert purged_receipt.payload_sha256 == old_receipt.payload_sha256

    assert untouched_receipt.raw_body == fresh_receipt.raw_body
    assert untouched_receipt.headers != %{}
    assert untouched_receipt.evidence_purged_at == nil

    assert 1 ==
             AuditLog
             |> Ash.Query.filter(expr(action == "WEBHOOK_EVIDENCE_PURGED"))
             |> Ash.count!(domain: Store.Admin, authorize?: false, context: %{system?: true})
  end

  defp create_receipt!(attrs) do
    defaults = %{
      provider: "stripe",
      event_type: "payment_intent.succeeded",
      verification_status: "verified",
      processing_status: "processed",
      headers: %{"content-type" => ["application/json"]},
      payload_sha256:
        :crypto.hash(:sha256, Map.fetch!(attrs, :raw_body))
        |> Base.encode16(case: :lower),
      verified_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      processed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, Map.merge(defaults, attrs), context: %{system?: true})
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp fetch_receipt!(id) do
    WebhookReceipt
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> List.first()
  end
end
