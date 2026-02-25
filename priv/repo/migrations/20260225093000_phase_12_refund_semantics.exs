defmodule Store.Repo.Migrations.Phase12RefundSemantics do
  @moduledoc """
  Adds refund evidence resources and captured amount fields for phase-12 semantics.
  """

  use Ecto.Migration

  def up do
    alter table(:payment_intents) do
      add :amount_received_minor, :bigint, null: false, default: 0
      add :currency, :text, null: false, default: "USD"
    end

    create table(:refunds, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            column: :id,
            type: :uuid,
            name: "refunds_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :payment_intent_id,
          references(:payment_intents,
            column: :id,
            type: :uuid,
            name: "refunds_payment_intent_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :state, :text, null: false, default: "requested"
      add :provider, :text, null: false, default: "stripe"
      add :provider_refund_id, :text
      add :requested_amount_minor, :bigint, null: false
      add :currency, :text, null: false
      add :reason, :text, null: false, default: "unspecified"
      add :scope_hash, :text, null: false
      add :idempotency_key, :text, null: false
      add :requested_by_user_id, :uuid

      add :requested_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :submitted_at, :utc_datetime_usec
      add :finalized_at, :utc_datetime_usec
      add :version, :bigint, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:refunds, [:idempotency_key],
             name: "refunds_unique_idempotency_key_index"
           )

    create unique_index(:refunds, [:provider, :provider_refund_id],
             where: "provider_refund_id IS NOT NULL",
             name: "refunds_unique_provider_refund_id_index"
           )

    create index(:refunds, [:order_id], name: "refunds_order_id_index")
    create index(:refunds, [:payment_intent_id], name: "refunds_payment_intent_id_index")
    create index(:refunds, [:state], name: "refunds_state_index")

    create constraint(:refunds, "refunds_requested_amount_minor_positive",
             check: "requested_amount_minor > 0"
           )

    create table(:refund_attempts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :refund_id,
          references(:refunds,
            column: :id,
            type: :uuid,
            name: "refund_attempts_refund_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :provider, :text, null: false, default: "stripe"
      add :provider_event_id, :text, null: false
      add :provider_event_key, :text, null: false
      add :provider_refund_id, :text
      add :outcome, :text, null: false
      add :error_code, :text
      add :error_message, :text
      add :payload_sha256, :text

      add :attempted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :sequence_no, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:refund_attempts, [:refund_id, :sequence_no],
             name: "refund_attempts_unique_refund_sequence_no_index"
           )

    create unique_index(:refund_attempts, [:provider_event_key],
             name: "refund_attempts_unique_provider_event_key_index"
           )

    create index(:refund_attempts, [:refund_id], name: "refund_attempts_refund_id_index")

    create index(:refund_attempts, [:provider_event_key],
             name: "refund_attempts_provider_event_key_index"
           )

    create index(:refund_attempts, [:attempted_at], name: "refund_attempts_attempted_at_index")

    create table(:refund_adjustments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            column: :id,
            type: :uuid,
            name: "refund_adjustments_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :refund_id,
          references(:refunds,
            column: :id,
            type: :uuid,
            name: "refund_adjustments_refund_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :currency, :text, null: false
      add :kind, :text, null: false, default: "refund"
      add :amount_minor, :bigint, null: false
      add :reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:refund_adjustments, [:refund_id],
             name: "refund_adjustments_unique_refund_adjustment_refund_index"
           )

    create index(:refund_adjustments, [:order_id], name: "refund_adjustments_order_id_index")
    create index(:refund_adjustments, [:refund_id], name: "refund_adjustments_refund_id_index")
  end

  def down do
    drop_if_exists index(:refund_adjustments, [:refund_id],
                     name: "refund_adjustments_refund_id_index"
                   )

    drop_if_exists index(:refund_adjustments, [:order_id],
                     name: "refund_adjustments_order_id_index"
                   )

    drop_if_exists unique_index(:refund_adjustments, [:refund_id],
                     name: "refund_adjustments_unique_refund_adjustment_refund_index"
                   )

    drop table(:refund_adjustments)

    drop_if_exists index(:refund_attempts, [:attempted_at],
                     name: "refund_attempts_attempted_at_index"
                   )

    drop_if_exists index(:refund_attempts, [:provider_event_key],
                     name: "refund_attempts_provider_event_key_index"
                   )

    drop_if_exists index(:refund_attempts, [:refund_id], name: "refund_attempts_refund_id_index")

    drop_if_exists unique_index(:refund_attempts, [:provider_event_key],
                     name: "refund_attempts_unique_provider_event_key_index"
                   )

    drop_if_exists unique_index(:refund_attempts, [:refund_id, :sequence_no],
                     name: "refund_attempts_unique_refund_sequence_no_index"
                   )

    drop table(:refund_attempts)

    drop constraint(:refunds, "refunds_requested_amount_minor_positive")
    drop_if_exists index(:refunds, [:state], name: "refunds_state_index")
    drop_if_exists index(:refunds, [:payment_intent_id], name: "refunds_payment_intent_id_index")
    drop_if_exists index(:refunds, [:order_id], name: "refunds_order_id_index")

    drop_if_exists unique_index(:refunds, [:provider, :provider_refund_id],
                     where: "provider_refund_id IS NOT NULL",
                     name: "refunds_unique_provider_refund_id_index"
                   )

    drop_if_exists unique_index(:refunds, [:idempotency_key],
                     name: "refunds_unique_idempotency_key_index"
                   )

    drop table(:refunds)

    alter table(:payment_intents) do
      remove :currency
      remove :amount_received_minor
    end
  end
end
