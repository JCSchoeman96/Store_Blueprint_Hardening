defmodule Store.Repo.Migrations.Phase21PaymentIntentProviderSessionFix do
  @moduledoc """
  Repairs payment intent provider session columns/indexes for databases that ran an earlier
  draft of phase 21 before provider_session_id was added.
  """

  use Ecto.Migration

  def up do
    execute(
      """
      ALTER TABLE payment_intents
      ADD COLUMN IF NOT EXISTS provider_session_id text
      """,
      """
      ALTER TABLE payment_intents
      DROP COLUMN IF EXISTS provider_session_id
      """
    )

    execute(
      """
      CREATE INDEX IF NOT EXISTS payment_intents_provider_session_id_index
      ON payment_intents (provider_session_id)
      """,
      """
      DROP INDEX IF EXISTS payment_intents_provider_session_id_index
      """
    )

    execute(
      """
      CREATE UNIQUE INDEX IF NOT EXISTS payment_intents_unique_provider_session_id_index
      ON payment_intents (provider, provider_session_id)
      WHERE provider_session_id IS NOT NULL
      """,
      """
      DROP INDEX IF EXISTS payment_intents_unique_provider_session_id_index
      """
    )
  end

  def down do
    execute(
      """
      DROP INDEX IF EXISTS payment_intents_unique_provider_session_id_index
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS payment_intents_unique_provider_session_id_index
      ON payment_intents (provider, provider_session_id)
      WHERE provider_session_id IS NOT NULL
      """
    )

    execute(
      """
      DROP INDEX IF EXISTS payment_intents_provider_session_id_index
      """,
      """
      CREATE INDEX IF NOT EXISTS payment_intents_provider_session_id_index
      ON payment_intents (provider_session_id)
      """
    )

    execute(
      """
      ALTER TABLE payment_intents
      DROP COLUMN IF EXISTS provider_session_id
      """,
      """
      ALTER TABLE payment_intents
      ADD COLUMN IF NOT EXISTS provider_session_id text
      """
    )
  end
end
