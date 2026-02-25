defmodule Store.Repo.Migrations.Phase14CheckoutInterlocks do
  @moduledoc """
  Adds checkout/payment interlock keys and replay-safe paid application evidence.
  """

  use Ecto.Migration

  def up do
    alter table(:orders) do
      add :checkout_key, :text
    end

    create unique_index(:orders, [:checkout_key], name: "orders_unique_checkout_key_index")

    alter table(:payment_intents) do
      add :payment_intent_key, :text
    end

    create unique_index(:payment_intents, [:payment_intent_key],
             name: "payment_intents_unique_payment_intent_key_index"
           )

    create unique_index(:payment_intents, [:order_id],
             where: "order_id IS NOT NULL AND state IN ('submitted', 'requires_action')",
             name: "payment_intents_unique_in_flight_order_id_index"
           )

    create table(:payment_attempts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :payment_intent_id,
          references(:payment_intents,
            column: :id,
            type: :uuid,
            name: "payment_attempts_payment_intent_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :provider, :text, null: false, default: "stripe"
      add :provider_event_id, :text, null: false
      add :provider_event_key, :text, null: false
      add :attempt_key, :text, null: false
      add :outcome, :text, null: false
      add :payload_sha256, :text

      add :attempted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:payment_attempts, [:payment_intent_id],
             name: "payment_attempts_payment_intent_id_index"
           )

    create index(:payment_attempts, [:attempted_at], name: "payment_attempts_attempted_at_index")

    create unique_index(:payment_attempts, [:provider_event_key],
             name: "payment_attempts_unique_provider_event_key_index"
           )

    create unique_index(:payment_attempts, [:attempt_key],
             name: "payment_attempts_unique_attempt_key_index"
           )

    create table(:payment_applications, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            column: :id,
            type: :uuid,
            name: "payment_applications_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :payment_intent_id,
          references(:payment_intents,
            column: :id,
            type: :uuid,
            name: "payment_applications_payment_intent_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :application_key, :text, null: false

      add :applied_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:payment_applications, [:order_id], name: "payment_applications_order_id_index")

    create index(:payment_applications, [:payment_intent_id],
             name: "payment_applications_payment_intent_id_index"
           )

    create unique_index(:payment_applications, [:application_key],
             name: "payment_applications_unique_application_key_index"
           )
  end

  def down do
    drop_if_exists unique_index(:payment_applications, [:application_key],
                     name: "payment_applications_unique_application_key_index"
                   )

    drop_if_exists index(:payment_applications, [:payment_intent_id],
                     name: "payment_applications_payment_intent_id_index"
                   )

    drop_if_exists index(:payment_applications, [:order_id],
                     name: "payment_applications_order_id_index"
                   )

    drop table(:payment_applications)

    drop_if_exists unique_index(:payment_attempts, [:attempt_key],
                     name: "payment_attempts_unique_attempt_key_index"
                   )

    drop_if_exists unique_index(:payment_attempts, [:provider_event_key],
                     name: "payment_attempts_unique_provider_event_key_index"
                   )

    drop_if_exists index(:payment_attempts, [:attempted_at],
                     name: "payment_attempts_attempted_at_index"
                   )

    drop_if_exists index(:payment_attempts, [:payment_intent_id],
                     name: "payment_attempts_payment_intent_id_index"
                   )

    drop table(:payment_attempts)

    drop_if_exists unique_index(:payment_intents, [:order_id],
                     where: "order_id IS NOT NULL AND state IN ('submitted', 'requires_action')",
                     name: "payment_intents_unique_in_flight_order_id_index"
                   )

    drop_if_exists unique_index(:payment_intents, [:payment_intent_key],
                     name: "payment_intents_unique_payment_intent_key_index"
                   )

    alter table(:payment_intents) do
      remove :payment_intent_key
    end

    drop_if_exists unique_index(:orders, [:checkout_key],
                     name: "orders_unique_checkout_key_index"
                   )

    alter table(:orders) do
      remove :checkout_key
    end
  end
end
