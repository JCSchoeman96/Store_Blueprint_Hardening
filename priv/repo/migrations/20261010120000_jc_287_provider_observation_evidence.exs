defmodule Store.Repo.Migrations.Jc287ProviderObservationEvidence do
  @moduledoc "Generalizes immutable payment attempts to persist provider observations."

  use Ecto.Migration

  def up do
    alter table(:payment_attempts) do
      modify :provider_event_id, :text, null: true
      modify :provider_event_key, :text, null: true
      add :provider_reference, :text
      add :provider_transaction_id, :text
      add :observation_source, :text, null: false, default: "webhook"
      add :raw_provider_status, :text
      add :amount_minor, :bigint
      add :currency, :text
      add :provider_environment, :text
      add :provider_occurred_at, :utc_datetime_usec

      add :observed_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    execute("""
    UPDATE payment_attempts
       SET observation_source = 'webhook',
           observed_at = attempted_at,
           outcome = CASE outcome
             WHEN 'succeeded' THEN 'authoritative_success'
             WHEN 'failed' THEN 'failure_observation'
             ELSE 'unknown_or_contradictory'
           END
    """)

    create index(:payment_attempts, [:provider, :provider_reference],
             name: "payment_attempts_provider_reference_index"
           )

    create index(:payment_attempts, [:payment_intent_id, :observed_at],
             name: "payment_attempts_intent_observed_index"
           )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM payment_attempts
         WHERE provider_event_id IS NULL
            OR provider_event_key IS NULL
            OR provider_reference IS NOT NULL
            OR provider_transaction_id IS NOT NULL
            OR observation_source <> 'webhook'
            OR raw_provider_status IS NOT NULL
            OR amount_minor IS NOT NULL
            OR currency IS NOT NULL
            OR provider_environment IS NOT NULL
            OR provider_occurred_at IS NOT NULL
            OR observed_at IS DISTINCT FROM attempted_at
      ) THEN
        RAISE EXCEPTION 'cannot roll back provider observations without losing durable evidence';
      END IF;
    END
    $$;
    """)

    execute("""
    UPDATE payment_attempts
       SET outcome = CASE outcome
         WHEN 'authoritative_success' THEN 'succeeded'
         WHEN 'failure_observation' THEN 'failed'
         ELSE 'ignored'
       END
    """)

    drop_if_exists index(:payment_attempts, [:payment_intent_id, :observed_at],
                     name: "payment_attempts_intent_observed_index"
                   )

    drop_if_exists index(:payment_attempts, [:provider, :provider_reference],
                     name: "payment_attempts_provider_reference_index"
                   )

    alter table(:payment_attempts) do
      remove :observed_at
      remove :provider_occurred_at
      remove :provider_environment
      remove :currency
      remove :amount_minor
      remove :raw_provider_status
      remove :observation_source
      remove :provider_transaction_id
      remove :provider_reference
    end

    alter table(:payment_attempts) do
      modify :provider_event_id, :text, null: false
      modify :provider_event_key, :text, null: false
    end
  end
end
