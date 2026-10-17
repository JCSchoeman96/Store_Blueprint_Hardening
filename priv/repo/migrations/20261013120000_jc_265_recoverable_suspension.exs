defmodule Store.Repo.Migrations.Jc265RecoverableSuspension do
  @moduledoc """
  Adds the recoverable suspended Subscription state to the database lifecycle
  constraint and open-membership uniqueness fence.
  """

  use Ecto.Migration

  @index_name "subscriptions_unique_open_membership_key_index"
  @status_constraint "subscriptions_status_value_check"

  def up do
    drop_if_exists(unique_index(:subscriptions, [:user_id, :membership_key], name: @index_name))

    create(
      unique_index(:subscriptions, [:user_id, :membership_key],
        where:
          "membership_key IS NOT NULL AND ended_at IS NULL AND status IN ('pending', 'active', 'past_due', 'suspended')",
        name: @index_name
      )
    )

    drop_if_exists(constraint(:subscriptions, @status_constraint))

    create(
      constraint(:subscriptions, @status_constraint,
        check: "status IN ('pending', 'active', 'past_due', 'suspended', 'canceled', 'expired')"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM subscriptions WHERE status = 'suspended') THEN
        RAISE EXCEPTION 'cannot roll back JC-265 while suspended subscriptions exist';
      END IF;
    END;
    $$;
    """)

    drop_if_exists(unique_index(:subscriptions, [:user_id, :membership_key], name: @index_name))

    create(
      unique_index(:subscriptions, [:user_id, :membership_key],
        where:
          "membership_key IS NOT NULL AND ended_at IS NULL AND status IN ('pending', 'active', 'past_due')",
        name: @index_name
      )
    )

    drop_if_exists(constraint(:subscriptions, @status_constraint))

    create(
      constraint(:subscriptions, @status_constraint,
        check: "status IN ('pending', 'active', 'past_due', 'canceled', 'expired')"
      )
    )
  end
end
