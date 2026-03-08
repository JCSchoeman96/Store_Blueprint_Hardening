defmodule Store.Repo.Migrations.Phase27SubscriptionContractPricingSnapshots do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :variant_id,
          references(:variants,
            column: :id,
            type: :uuid,
            name: "subscriptions_variant_id_fkey"
          )

      add :quantity, :integer, default: 1
      add :renewal_amount_minor, :bigint
      add :renewal_currency, :string, size: 3
      add :membership_key, :string

      add :pending_variant_id,
          references(:variants,
            column: :id,
            type: :uuid,
            name: "subscriptions_pending_variant_id_fkey"
          )

      add :pending_subscription_plan_id,
          references(:subscription_plans,
            column: :id,
            type: :uuid,
            name: "subscriptions_pending_subscription_plan_id_fkey"
          )

      add :pending_renewal_amount_minor, :bigint
      add :pending_renewal_currency, :string, size: 3
      add :change_effective_at, :utc_datetime_usec
      add :dunning_attempt_count, :integer, default: 0, null: false
      add :next_retry_at, :utc_datetime_usec
    end

    execute("""
    UPDATE subscriptions AS s
    SET variant_id = oli.variant_id_snapshot,
        quantity = COALESCE(s.quantity, oli.quantity, 1),
        renewal_amount_minor = oli.unit_price_minor,
        renewal_currency = UPPER(oli.currency)
    FROM order_line_items AS oli
    WHERE oli.id = s.source_order_line_item_id
    """)

    execute("""
    UPDATE subscriptions AS s
    SET variant_id = si.variant_id,
        quantity = COALESCE(s.quantity, si.quantity, 1),
        renewal_amount_minor = COALESCE(s.renewal_amount_minor, si.amount_minor_snapshot),
        renewal_currency = COALESCE(s.renewal_currency, UPPER(si.currency_snapshot))
    FROM subscription_items AS si
    WHERE si.subscription_id = s.id
      AND (s.variant_id IS NULL OR s.renewal_amount_minor IS NULL OR s.renewal_currency IS NULL)
    """)

    execute("""
    UPDATE subscriptions AS s
    SET membership_key = sp.entitlement_scope_key
    FROM subscription_plans AS sp
    WHERE sp.id = s.subscription_plan_id
      AND sp.entitlement_kind = 'membership_access'
      AND sp.entitlement_scope_key IS NOT NULL
    """)

    execute("UPDATE subscriptions SET quantity = 1 WHERE quantity IS NULL")

    execute(
      "UPDATE subscriptions SET dunning_attempt_count = 0 WHERE dunning_attempt_count IS NULL"
    )

    execute("ALTER TABLE subscriptions ALTER COLUMN variant_id SET NOT NULL")
    execute("ALTER TABLE subscriptions ALTER COLUMN quantity SET NOT NULL")
    execute("ALTER TABLE subscriptions ALTER COLUMN renewal_amount_minor SET NOT NULL")
    execute("ALTER TABLE subscriptions ALTER COLUMN renewal_currency SET NOT NULL")

    create(index(:subscriptions, [:variant_id], name: "subscriptions_variant_id_index"))

    create(
      index(:subscriptions, [:pending_subscription_plan_id],
        name: "subscriptions_pending_plan_id_index"
      )
    )

    create(
      index(:subscriptions, [:pending_variant_id], name: "subscriptions_pending_variant_id_index")
    )

    create(
      index(:subscriptions, [:status, :next_retry_at],
        name: "subscriptions_status_next_retry_at_index"
      )
    )

    create(
      index(:subscriptions, [:user_id, :membership_key],
        name: "subscriptions_user_membership_key_index"
      )
    )

    create(
      unique_index(:subscriptions, [:user_id, :membership_key],
        where:
          "membership_key IS NOT NULL AND ended_at IS NULL AND status IN ('pending', 'active', 'past_due')",
        name: "subscriptions_unique_open_membership_key_index"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_quantity_positive_check",
        check: "quantity > 0"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_renewal_amount_minor_non_negative_check",
        check: "renewal_amount_minor >= 0"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_pending_renewal_amount_minor_non_negative_check",
        check: "pending_renewal_amount_minor IS NULL OR pending_renewal_amount_minor >= 0"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_dunning_attempt_count_non_negative_check",
        check: "dunning_attempt_count >= 0"
      )
    )
  end

  def down do
    drop_if_exists(
      constraint(:subscriptions, "subscriptions_dunning_attempt_count_non_negative_check")
    )

    drop_if_exists(
      constraint(:subscriptions, "subscriptions_pending_renewal_amount_minor_non_negative_check")
    )

    drop_if_exists(
      constraint(:subscriptions, "subscriptions_renewal_amount_minor_non_negative_check")
    )

    drop_if_exists(constraint(:subscriptions, "subscriptions_quantity_positive_check"))

    drop_if_exists(
      unique_index(:subscriptions, [:user_id, :membership_key],
        name: "subscriptions_unique_open_membership_key_index"
      )
    )

    drop_if_exists(
      index(:subscriptions, [:user_id, :membership_key],
        name: "subscriptions_user_membership_key_index"
      )
    )

    drop_if_exists(
      index(:subscriptions, [:status, :next_retry_at],
        name: "subscriptions_status_next_retry_at_index"
      )
    )

    drop_if_exists(
      index(:subscriptions, [:pending_variant_id], name: "subscriptions_pending_variant_id_index")
    )

    drop_if_exists(
      index(:subscriptions, [:pending_subscription_plan_id],
        name: "subscriptions_pending_plan_id_index"
      )
    )

    drop_if_exists(index(:subscriptions, [:variant_id], name: "subscriptions_variant_id_index"))

    alter table(:subscriptions) do
      remove :next_retry_at
      remove :dunning_attempt_count
      remove :change_effective_at
      remove :pending_renewal_currency
      remove :pending_renewal_amount_minor
      remove :pending_subscription_plan_id
      remove :pending_variant_id
      remove :membership_key
      remove :renewal_currency
      remove :renewal_amount_minor
      remove :quantity
      remove :variant_id
    end
  end
end
