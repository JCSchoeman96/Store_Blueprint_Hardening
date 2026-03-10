defmodule Store.Repo.Migrations.Phase28WebhookReceiptEvidenceRetention do
  use Ecto.Migration

  def change do
    alter table(:webhook_receipts) do
      add :evidence_purged_at, :utc_datetime_usec
    end

    create index(:webhook_receipts, [:evidence_purged_at],
             name: "webhook_receipts_evidence_purged_at_index"
           )
  end
end
