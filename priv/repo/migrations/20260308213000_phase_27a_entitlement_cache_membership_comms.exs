defmodule Store.Repo.Migrations.Phase27aEntitlementCacheMembershipComms do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    execute(
      "ALTER TYPE email_template_kind ADD VALUE IF NOT EXISTS 'payment_authentication_required'"
    )

    execute("ALTER TYPE email_template_kind ADD VALUE IF NOT EXISTS 'renewal_reminder'")
    execute("ALTER TYPE email_template_kind ADD VALUE IF NOT EXISTS 'access_ended'")

    execute("ALTER TABLE email_outboxes ALTER COLUMN order_id DROP NOT NULL")

    alter table(:email_outboxes) do
      add :subscription_id, references(:subscriptions, type: :uuid, on_delete: :delete_all)
    end

    create index(:email_outboxes, [:subscription_id],
             name: "email_outboxes_subscription_id_index"
           )

    drop constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check")

    create(
      constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check",
        check: """
        (
          order_id IS NOT NULL
          AND refund_id IS NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'order_receipt'::email_template_kind,
            'payment_authentication_required'::email_template_kind
          )
        ) OR (
          order_id IS NOT NULL
          AND refund_id IS NOT NULL
          AND subscription_id IS NULL
          AND template_kind IN (
            'refund_requested'::email_template_kind,
            'refund_processed'::email_template_kind
          )
        ) OR (
          order_id IS NULL
          AND refund_id IS NULL
          AND subscription_id IS NOT NULL
          AND template_kind IN (
            'renewal_reminder'::email_template_kind,
            'access_ended'::email_template_kind
          )
        )
        """
      )
    )
  end

  def down do
    drop_if_exists(
      index(:email_outboxes, [:subscription_id], name: "email_outboxes_subscription_id_index")
    )

    drop constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check")

    create(
      constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check",
        check: """
        (
          refund_id IS NULL AND template_kind = 'order_receipt'::email_template_kind
        ) OR (
          refund_id IS NOT NULL AND template_kind IN (
            'refund_requested'::email_template_kind,
            'refund_processed'::email_template_kind
          )
        )
        """
      )
    )

    execute("ALTER TABLE email_outboxes ALTER COLUMN order_id SET NOT NULL")

    alter table(:email_outboxes) do
      remove :subscription_id
    end
  end
end
