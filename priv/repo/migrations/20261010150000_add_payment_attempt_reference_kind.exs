defmodule Store.Repo.Migrations.AddPaymentAttemptReferenceKind do
  @moduledoc "Persists the provider resource kind for payment evidence references."

  use Ecto.Migration

  def up do
    alter table(:payment_attempts) do
      add :provider_reference_kind, :text
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM payment_attempts WHERE provider_reference_kind IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'cannot drop provider reference kinds from durable payment evidence';
      END IF;
    END
    $$;
    """)

    alter table(:payment_attempts) do
      remove :provider_reference_kind
    end
  end
end
