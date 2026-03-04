defmodule Store.Repo.Migrations.ValidateObanNonNegativePriorityConstraintBackstop do
  @moduledoc """
  Backstop validation for Oban's non_negative_priority constraint.

  This exists to cover environments that may have applied a different migration
  body under version 20260304123000 before the current repository state.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = 'oban_jobs'
          AND c.conname = 'non_negative_priority'
          AND c.contype = 'c'
          AND c.convalidated = false
      ) THEN
        ALTER TABLE public.oban_jobs
        VALIDATE CONSTRAINT non_negative_priority;
      END IF;
    END
    $$;
    """)
  end

  def down, do: :ok
end
