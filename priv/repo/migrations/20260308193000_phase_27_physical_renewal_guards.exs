defmodule Store.Repo.Migrations.Phase27PhysicalRenewalGuards do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :retry_suppressed_at, :utc_datetime_usec
    end

    drop_if_exists index(:subscriptions, [:status, :next_renewal_at],
                     name: "subscriptions_status_next_renewal_at_index"
                   )

    drop_if_exists index(:subscriptions, [:status, :next_retry_at],
                     name: "subscriptions_status_next_retry_at_index"
                   )

    execute(
      """
      CREATE INDEX subscriptions_active_due_tick_idx
      ON subscriptions (next_renewal_at)
      WHERE status = 'active' AND cancel_at_period_end = false
      """,
      "DROP INDEX IF EXISTS subscriptions_active_due_tick_idx"
    )

    execute(
      """
      CREATE INDEX subscriptions_past_due_tick_idx
      ON subscriptions (next_retry_at)
      WHERE status = 'past_due' AND retry_suppressed_at IS NULL AND cancel_at_period_end = false
      """,
      "DROP INDEX IF EXISTS subscriptions_past_due_tick_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS subscriptions_active_due_tick_idx")
    execute("DROP INDEX IF EXISTS subscriptions_past_due_tick_idx")

    create index(:subscriptions, [:status, :next_renewal_at],
             name: "subscriptions_status_next_renewal_at_index"
           )

    create index(:subscriptions, [:status, :next_retry_at],
             name: "subscriptions_status_next_retry_at_index"
           )

    alter table(:subscriptions) do
      remove :retry_suppressed_at
    end
  end
end
