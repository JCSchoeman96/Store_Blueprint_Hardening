defmodule Store.Repo.Migrations.Phase23EmailNotificationsSpine do
  @moduledoc """
  Upgrades email outbox to phase-23 delivery spine invariants:

  - template_kind string -> enum
  - provider + template assigns + refund linkage
  - partial uniqueness constraints for receipt/refund flows
  - coherence check between refund_id and template_kind
  - processing_started_at for stale-claim recovery
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      CREATE TYPE email_template_kind AS ENUM ('order_receipt', 'refund_requested', 'refund_processed');
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END
    $$;
    """)

    alter table(:email_outboxes) do
      add(:template_kind_v2, :email_template_kind)
      add(:refund_id, references(:refunds, column: :id, type: :uuid, on_delete: :nothing))
      add(:provider, :text)
      add(:provider_message_id, :text)
      add(:template_assigns, :map, default: %{}, null: false)
      add(:processing_started_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE email_outboxes
    SET template_kind_v2 = CASE template_kind
      WHEN 'order_receipt' THEN 'order_receipt'::email_template_kind
      WHEN 'refund_requested' THEN 'refund_requested'::email_template_kind
      WHEN 'refund_processed' THEN 'refund_processed'::email_template_kind
      ELSE NULL
    END
    """)

    execute("""
    DO $$
    DECLARE
      unknown_count integer;
    BEGIN
      SELECT COUNT(*)
      INTO unknown_count
      FROM email_outboxes
      WHERE template_kind_v2 IS NULL;

      IF unknown_count > 0 THEN
        RAISE EXCEPTION 'unknown legacy template_kind values found in email_outboxes: %', unknown_count;
      END IF;
    END
    $$;
    """)

    execute("UPDATE email_outboxes SET provider = 'swoosh' WHERE provider IS NULL")

    execute("ALTER TABLE email_outboxes ALTER COLUMN provider SET NOT NULL")
    execute("ALTER TABLE email_outboxes ALTER COLUMN template_kind_v2 SET NOT NULL")

    drop_if_exists(
      unique_index(:email_outboxes, [:order_id, :template_kind],
        name: "email_outboxes_unique_order_template_kind_index"
      )
    )

    drop_if_exists(
      index(:email_outboxes, [:template_kind], name: "email_outboxes_template_kind_index")
    )

    drop_if_exists(index(:email_outboxes, [:state], name: "email_outboxes_state_index"))

    execute("ALTER TABLE email_outboxes RENAME COLUMN template_kind TO template_kind_legacy")
    execute("ALTER TABLE email_outboxes RENAME COLUMN template_kind_v2 TO template_kind")
    execute("ALTER TABLE email_outboxes DROP COLUMN template_kind_legacy")

    execute(
      """
      CREATE UNIQUE INDEX email_outboxes_unique_order_template_kind_no_refund_index
      ON email_outboxes (order_id, template_kind)
      WHERE refund_id IS NULL
      """,
      "DROP INDEX IF EXISTS email_outboxes_unique_order_template_kind_no_refund_index"
    )

    execute(
      """
      CREATE UNIQUE INDEX email_outboxes_unique_refund_template_kind_index
      ON email_outboxes (refund_id, template_kind)
      WHERE refund_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS email_outboxes_unique_refund_template_kind_index"
    )

    create(
      index(:email_outboxes, [:state, :inserted_at],
        name: "email_outboxes_state_inserted_at_index"
      )
    )

    create(
      index(:email_outboxes, [:template_kind, :inserted_at],
        name: "email_outboxes_template_kind_inserted_at_index"
      )
    )

    create(index(:email_outboxes, [:refund_id], name: "email_outboxes_refund_id_index"))

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

    create(
      constraint(:email_outboxes, "email_outboxes_provider_check",
        check: "provider IN ('swoosh', 'req_postmark')"
      )
    )
  end

  def down do
    drop(constraint(:email_outboxes, "email_outboxes_provider_check"))
    drop(constraint(:email_outboxes, "email_outboxes_template_kind_refund_coherence_check"))

    drop_if_exists(index(:email_outboxes, [:refund_id], name: "email_outboxes_refund_id_index"))

    drop_if_exists(
      index(:email_outboxes, [:template_kind, :inserted_at],
        name: "email_outboxes_template_kind_inserted_at_index"
      )
    )

    drop_if_exists(
      index(:email_outboxes, [:state, :inserted_at],
        name: "email_outboxes_state_inserted_at_index"
      )
    )

    execute("DROP INDEX IF EXISTS email_outboxes_unique_refund_template_kind_index")
    execute("DROP INDEX IF EXISTS email_outboxes_unique_order_template_kind_no_refund_index")

    alter table(:email_outboxes) do
      add(:template_kind_v1, :text)
    end

    execute("""
    UPDATE email_outboxes
    SET template_kind_v1 = CASE template_kind
      WHEN 'order_receipt'::email_template_kind THEN 'order_receipt'
      WHEN 'refund_requested'::email_template_kind THEN 'refund_requested'
      WHEN 'refund_processed'::email_template_kind THEN 'refund_processed'
      ELSE NULL
    END
    """)

    execute("ALTER TABLE email_outboxes ALTER COLUMN template_kind_v1 SET NOT NULL")

    execute("ALTER TABLE email_outboxes RENAME COLUMN template_kind TO template_kind_v2")
    execute("ALTER TABLE email_outboxes RENAME COLUMN template_kind_v1 TO template_kind")
    execute("ALTER TABLE email_outboxes DROP COLUMN template_kind_v2")

    alter table(:email_outboxes) do
      remove(:processing_started_at)
      remove(:template_assigns)
      remove(:provider_message_id)
      remove(:provider)
      remove(:refund_id)
    end

    create(index(:email_outboxes, [:state], name: "email_outboxes_state_index"))
    create(index(:email_outboxes, [:template_kind], name: "email_outboxes_template_kind_index"))

    create(
      unique_index(:email_outboxes, [:order_id, :template_kind],
        name: "email_outboxes_unique_order_template_kind_index"
      )
    )

    execute("""
    DO $$
    BEGIN
      DROP TYPE IF EXISTS email_template_kind;
    EXCEPTION
      WHEN dependent_objects_still_exist THEN NULL;
    END
    $$;
    """)
  end
end
