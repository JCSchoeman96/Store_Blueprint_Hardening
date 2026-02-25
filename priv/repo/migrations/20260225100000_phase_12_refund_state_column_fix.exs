defmodule Store.Repo.Migrations.Phase12RefundStateColumnFix do
  @moduledoc """
  Harmonizes refunds.state naming for environments that briefly had refunds.status.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refunds'
          AND column_name = 'status'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refunds'
          AND column_name = 'state'
      ) THEN
        ALTER TABLE refunds RENAME COLUMN status TO state;
      END IF;
    END
    $$;
    """)

    execute("DROP INDEX IF EXISTS refunds_status_index")
    execute("CREATE INDEX IF NOT EXISTS refunds_state_index ON refunds (state)")
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refunds'
          AND column_name = 'state'
      ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'refunds'
          AND column_name = 'status'
      ) THEN
        ALTER TABLE refunds RENAME COLUMN state TO status;
      END IF;
    END
    $$;
    """)

    execute("DROP INDEX IF EXISTS refunds_state_index")
    execute("CREATE INDEX IF NOT EXISTS refunds_status_index ON refunds (status)")
  end
end
