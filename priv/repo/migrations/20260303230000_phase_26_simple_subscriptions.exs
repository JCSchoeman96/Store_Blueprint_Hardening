defmodule Store.Repo.Migrations.Phase26SimpleSubscriptions do
  @moduledoc """
  Adds subscription and entitlement schema plus cart/order snapshot plan identity support.
  """

  use Ecto.Migration

  def up do
    alter table(:products) do
      add(:product_kind, :text, null: false, default: "simple")
    end

    create(index(:products, [:product_kind], name: "products_product_kind_index"))

    create(
      constraint(
        :products,
        "products_product_kind_value_check",
        check: "product_kind IN ('simple', 'subscription')"
      )
    )

    create table(:subscription_plans, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:key, :text, null: false)
      add(:name, :text, null: false)
      add(:status, :text, null: false, default: "active")
      add(:interval_unit, :text, null: false, default: "month")
      add(:interval_count, :bigint, null: false, default: 1)
      add(:currency, :text, null: false, default: "USD")
      add(:amount_minor, :bigint, null: false)
      add(:trial_days, :bigint)
      add(:anchor_mode, :text, null: false, default: "start_anniversary")
      add(:anchor_day_of_month, :bigint)
      add(:billing_timezone, :text, null: false, default: "Africa/Johannesburg")
      add(:term_mode, :text, null: false, default: "until_canceled")
      add(:term_cycles, :bigint)
      add(:term_end_at, :utc_datetime_usec)
      add(:access_on_past_due, :text, null: false, default: "keep_during_grace")
      add(:access_on_cancel, :text, null: false, default: "keep_until_period_end")
      add(:grace_period_days, :bigint, null: false, default: 7)
      add(:max_retry_attempts, :bigint, null: false, default: 3)
      add(:retry_schedule_hours, {:array, :bigint}, null: false, default: [0, 24, 72])
      add(:entitlement_kind, :text)
      add(:entitlement_scope_key, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:subscription_plans, [:key], name: "subscription_plans_unique_key_index"))
    create(index(:subscription_plans, [:status], name: "subscription_plans_status_index"))

    create(
      index(:subscription_plans, [:interval_unit, :interval_count],
        name: "subscription_plans_interval_index"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_status_value_check",
        check: "status IN ('active', 'archived')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_interval_unit_value_check",
        check: "interval_unit IN ('day', 'month', 'year')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_anchor_mode_value_check",
        check: "anchor_mode IN ('start_anniversary', 'fixed_day_of_month')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_term_mode_value_check",
        check: "term_mode IN ('until_canceled', 'fixed_cycles', 'fixed_end_at')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_access_on_past_due_value_check",
        check: "access_on_past_due IN ('keep_during_grace', 'remove_immediately')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_access_on_cancel_value_check",
        check: "access_on_cancel IN ('keep_until_period_end', 'remove_immediately')"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_interval_count_check",
        check: "interval_count >= 1"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_amount_minor_non_negative_check",
        check: "amount_minor >= 0"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_anchor_day_requirement_check",
        check:
          "(anchor_mode <> 'fixed_day_of_month') OR (anchor_day_of_month >= 1 AND anchor_day_of_month <= 31)"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_term_cycles_requirement_check",
        check: "(term_mode <> 'fixed_cycles') OR (term_cycles IS NOT NULL AND term_cycles >= 1)"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_term_end_requirement_check",
        check: "(term_mode <> 'fixed_end_at') OR (term_end_at IS NOT NULL)"
      )
    )

    create(
      constraint(
        :subscription_plans,
        "subscription_plans_retry_schedule_not_empty_check",
        check: "array_length(retry_schedule_hours, 1) >= 1"
      )
    )

    create table(:variant_subscription_plans, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :variant_id,
        references(:variants,
          column: :id,
          type: :uuid,
          name: "variant_subscription_plans_variant_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :subscription_plan_id,
        references(:subscription_plans,
          column: :id,
          type: :uuid,
          name: "variant_subscription_plans_subscription_plan_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:active, :boolean, null: false, default: true)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:variant_subscription_plans, [:variant_id, :subscription_plan_id],
        name: "variant_subscription_plans_unique_variant_plan_index"
      )
    )

    create(
      unique_index(:variant_subscription_plans, [:variant_id],
        where: "active = true",
        name: "variant_subscription_plans_unique_active_variant_index"
      )
    )

    create(
      index(:variant_subscription_plans, [:subscription_plan_id],
        name: "variant_subscription_plans_plan_id_index"
      )
    )

    create(
      index(:variant_subscription_plans, [:active],
        name: "variant_subscription_plans_active_index"
      )
    )

    alter table(:cart_items) do
      add(
        :subscription_plan_id,
        references(:subscription_plans,
          column: :id,
          type: :uuid,
          name: "cart_items_subscription_plan_id_fkey",
          on_delete: :nilify_all
        )
      )
    end

    drop_if_exists(
      unique_index(:cart_items, [:cart_id, :variant_id],
        name: "cart_items_unique_cart_variant_index"
      )
    )

    create(
      unique_index(:cart_items, [:cart_id, :variant_id],
        where: "subscription_plan_id IS NULL",
        name: "cart_items_unique_cart_variant_no_plan_index"
      )
    )

    create(
      unique_index(:cart_items, [:cart_id, :variant_id, :subscription_plan_id],
        where: "subscription_plan_id IS NOT NULL",
        name: "cart_items_unique_cart_variant_plan_index"
      )
    )

    create(
      index(:cart_items, [:subscription_plan_id], name: "cart_items_subscription_plan_id_index")
    )

    alter table(:order_line_items) do
      add(:subscription_plan_id_snapshot, :uuid)
      add(:subscription_plan_key_snapshot, :text)
      add(:subscription_interval_unit_snapshot, :text)
      add(:subscription_interval_count_snapshot, :bigint)
    end

    create(
      index(:order_line_items, [:subscription_plan_id_snapshot],
        name: "order_line_items_subscription_plan_id_snapshot_index"
      )
    )

    create table(:subscriptions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :user_id,
        references(:users,
          column: :id,
          type: :uuid,
          name: "subscriptions_user_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :subscription_plan_id,
        references(:subscription_plans,
          column: :id,
          type: :uuid,
          name: "subscriptions_subscription_plan_id_fkey",
          on_delete: :restrict
        ),
        null: false
      )

      add(:status, :text, null: false, default: "pending")
      add(:provider, :text, null: false, default: "stripe")
      add(:provider_subscription_id, :text)
      add(:billing_mode, :text, null: false, default: "merchant_managed")
      add(:billing_status_reason, :text)
      add(:cancel_at_period_end, :boolean, null: false, default: false)
      add(:started_at, :utc_datetime_usec)
      add(:current_period_start_at, :utc_datetime_usec)
      add(:current_period_end_at, :utc_datetime_usec)
      add(:next_renewal_at, :utc_datetime_usec)
      add(:past_due_since_at, :utc_datetime_usec)
      add(:canceled_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:canceled_reason, :text)
      add(:provider_customer_ref, :text)
      add(:provider_billing_ref, :text)

      add(
        :source_order_id,
        references(:orders,
          column: :id,
          type: :uuid,
          name: "subscriptions_source_order_id_fkey",
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :source_order_line_item_id,
        references(:order_line_items,
          column: :id,
          type: :uuid,
          name: "subscriptions_source_order_line_item_id_fkey",
          on_delete: :restrict
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:subscriptions, [:source_order_line_item_id],
        name: "subscriptions_unique_source_order_line_item_id_index"
      )
    )

    create(
      unique_index(:subscriptions, [:provider, :provider_subscription_id],
        where: "provider_subscription_id IS NOT NULL",
        name: "subscriptions_unique_provider_subscription_id_index"
      )
    )

    create(index(:subscriptions, [:user_id, :status], name: "subscriptions_user_id_status_index"))

    create(
      index(:subscriptions, [:status, :next_renewal_at],
        name: "subscriptions_status_next_renewal_at_index"
      )
    )

    create(
      index(:subscriptions, [:subscription_plan_id],
        name: "subscriptions_subscription_plan_id_index"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_status_value_check",
        check: "status IN ('pending', 'active', 'past_due', 'canceled', 'expired')"
      )
    )

    create(
      constraint(
        :subscriptions,
        "subscriptions_billing_mode_value_check",
        check: "billing_mode IN ('merchant_managed', 'provider_managed')"
      )
    )

    create table(:subscription_items, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :subscription_id,
        references(:subscriptions,
          column: :id,
          type: :uuid,
          name: "subscription_items_subscription_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :variant_id,
        references(:variants,
          column: :id,
          type: :uuid,
          name: "subscription_items_variant_id_fkey",
          on_delete: :restrict
        ),
        null: false
      )

      add(:quantity, :bigint, null: false, default: 1)
      add(:plan_key_snapshot, :text, null: false)
      add(:amount_minor_snapshot, :bigint, null: false)
      add(:currency_snapshot, :text, null: false)
      add(:interval_unit_snapshot, :text, null: false)
      add(:interval_count_snapshot, :bigint, null: false)

      add(
        :source_order_line_item_id,
        references(:order_line_items,
          column: :id,
          type: :uuid,
          name: "subscription_items_source_order_line_item_id_fkey",
          on_delete: :restrict
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:subscription_items, [:source_order_line_item_id],
        name: "subscription_items_unique_source_order_line_item_id_index"
      )
    )

    create(
      index(:subscription_items, [:subscription_id],
        name: "subscription_items_subscription_id_index"
      )
    )

    create(index(:subscription_items, [:variant_id], name: "subscription_items_variant_id_index"))

    create(
      constraint(
        :subscription_items,
        "subscription_items_interval_unit_value_check",
        check: "interval_unit_snapshot IN ('day', 'month', 'year')"
      )
    )

    create(
      constraint(
        :subscription_items,
        "subscription_items_quantity_positive_check",
        check: "quantity >= 1"
      )
    )

    create(
      constraint(
        :subscription_items,
        "subscription_items_amount_minor_non_negative_check",
        check: "amount_minor_snapshot >= 0"
      )
    )

    create table(:renewal_attempts, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :subscription_id,
        references(:subscriptions,
          column: :id,
          type: :uuid,
          name: "renewal_attempts_subscription_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:period_start_at, :utc_datetime_usec, null: false)
      add(:period_end_at, :utc_datetime_usec, null: false)
      add(:renewal_key, :text, null: false)
      add(:status, :text, null: false, default: "pending")

      add(
        :order_id,
        references(:orders,
          column: :id,
          type: :uuid,
          name: "renewal_attempts_order_id_fkey",
          on_delete: :nilify_all
        )
      )

      add(
        :payment_intent_id,
        references(:payment_intents,
          column: :id,
          type: :uuid,
          name: "renewal_attempts_payment_intent_id_fkey",
          on_delete: :nilify_all
        )
      )

      add(:failure_code, :text)
      add(:failure_message, :text)
      add(:attempt_no, :bigint, null: false, default: 1)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:renewal_attempts, [:subscription_id, :renewal_key],
        name: "renewal_attempts_unique_subscription_renewal_key_index"
      )
    )

    create(
      index(:renewal_attempts, [:subscription_id], name: "renewal_attempts_subscription_id_index")
    )

    create(index(:renewal_attempts, [:inserted_at], name: "renewal_attempts_inserted_at_index"))

    create(
      index(:renewal_attempts, [:status, :inserted_at],
        name: "renewal_attempts_status_inserted_at_index"
      )
    )

    create(
      constraint(
        :renewal_attempts,
        "renewal_attempts_status_value_check",
        check: "status IN ('pending', 'processing', 'succeeded', 'failed')"
      )
    )

    create(
      constraint(
        :renewal_attempts,
        "renewal_attempts_attempt_no_positive_check",
        check: "attempt_no >= 1"
      )
    )

    create table(:entitlement_grants, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :user_id,
        references(:users,
          column: :id,
          type: :uuid,
          name: "entitlement_grants_user_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:kind, :text, null: false)
      add(:scope_key, :text, null: false)
      add(:source_kind, :text, null: false, default: "subscription")

      add(
        :source_id,
        references(:subscriptions,
          column: :id,
          type: :uuid,
          name: "entitlement_grants_source_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:status, :text, null: false, default: "active")

      add(:valid_from_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:valid_to_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_reason, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(
        :entitlement_grants,
        [:user_id, :kind, :scope_key, :source_kind, :source_id],
        name: "entitlement_grants_unique_user_scope_source_index"
      )
    )

    create(
      index(:entitlement_grants, [:user_id, :kind, :scope_key, :status],
        name: "entitlement_grants_lookup_index"
      )
    )

    create(
      index(:entitlement_grants, [:source_kind, :source_id],
        name: "entitlement_grants_source_index"
      )
    )

    create(
      index(:entitlement_grants, [:valid_to_at], name: "entitlement_grants_valid_to_at_index")
    )

    create(
      constraint(
        :entitlement_grants,
        "entitlement_grants_kind_value_check",
        check: "kind IN ('membership_access', 'digital_library', 'discount_tier')"
      )
    )

    create(
      constraint(
        :entitlement_grants,
        "entitlement_grants_source_kind_value_check",
        check: "source_kind IN ('subscription')"
      )
    )

    create(
      constraint(
        :entitlement_grants,
        "entitlement_grants_status_value_check",
        check: "status IN ('active', 'revoked', 'expired')"
      )
    )
  end

  def down do
    drop(constraint(:entitlement_grants, "entitlement_grants_status_value_check"))
    drop(constraint(:entitlement_grants, "entitlement_grants_source_kind_value_check"))
    drop(constraint(:entitlement_grants, "entitlement_grants_kind_value_check"))

    drop_if_exists(
      index(:entitlement_grants, [:valid_to_at], name: "entitlement_grants_valid_to_at_index")
    )

    drop_if_exists(
      index(:entitlement_grants, [:source_kind, :source_id],
        name: "entitlement_grants_source_index"
      )
    )

    drop_if_exists(
      index(:entitlement_grants, [:user_id, :kind, :scope_key, :status],
        name: "entitlement_grants_lookup_index"
      )
    )

    drop_if_exists(
      unique_index(
        :entitlement_grants,
        [:user_id, :kind, :scope_key, :source_kind, :source_id],
        name: "entitlement_grants_unique_user_scope_source_index"
      )
    )

    drop(table(:entitlement_grants))

    drop(constraint(:renewal_attempts, "renewal_attempts_attempt_no_positive_check"))
    drop(constraint(:renewal_attempts, "renewal_attempts_status_value_check"))

    drop_if_exists(
      index(:renewal_attempts, [:status, :inserted_at],
        name: "renewal_attempts_status_inserted_at_index"
      )
    )

    drop_if_exists(
      index(:renewal_attempts, [:inserted_at], name: "renewal_attempts_inserted_at_index")
    )

    drop_if_exists(
      index(:renewal_attempts, [:subscription_id], name: "renewal_attempts_subscription_id_index")
    )

    drop_if_exists(
      unique_index(:renewal_attempts, [:subscription_id, :renewal_key],
        name: "renewal_attempts_unique_subscription_renewal_key_index"
      )
    )

    drop(table(:renewal_attempts))

    drop(constraint(:subscription_items, "subscription_items_amount_minor_non_negative_check"))
    drop(constraint(:subscription_items, "subscription_items_quantity_positive_check"))
    drop(constraint(:subscription_items, "subscription_items_interval_unit_value_check"))

    drop_if_exists(
      index(:subscription_items, [:variant_id], name: "subscription_items_variant_id_index")
    )

    drop_if_exists(
      index(:subscription_items, [:subscription_id],
        name: "subscription_items_subscription_id_index"
      )
    )

    drop_if_exists(
      unique_index(:subscription_items, [:source_order_line_item_id],
        name: "subscription_items_unique_source_order_line_item_id_index"
      )
    )

    drop(table(:subscription_items))

    drop(constraint(:subscriptions, "subscriptions_billing_mode_value_check"))
    drop(constraint(:subscriptions, "subscriptions_status_value_check"))

    drop_if_exists(
      index(:subscriptions, [:subscription_plan_id],
        name: "subscriptions_subscription_plan_id_index"
      )
    )

    drop_if_exists(
      index(:subscriptions, [:status, :next_renewal_at],
        name: "subscriptions_status_next_renewal_at_index"
      )
    )

    drop_if_exists(
      index(:subscriptions, [:user_id, :status], name: "subscriptions_user_id_status_index")
    )

    drop_if_exists(
      unique_index(:subscriptions, [:provider, :provider_subscription_id],
        where: "provider_subscription_id IS NOT NULL",
        name: "subscriptions_unique_provider_subscription_id_index"
      )
    )

    drop_if_exists(
      unique_index(:subscriptions, [:source_order_line_item_id],
        name: "subscriptions_unique_source_order_line_item_id_index"
      )
    )

    drop(table(:subscriptions))

    drop_if_exists(
      index(:order_line_items, [:subscription_plan_id_snapshot],
        name: "order_line_items_subscription_plan_id_snapshot_index"
      )
    )

    alter table(:order_line_items) do
      remove(:subscription_interval_count_snapshot)
      remove(:subscription_interval_unit_snapshot)
      remove(:subscription_plan_key_snapshot)
      remove(:subscription_plan_id_snapshot)
    end

    drop_if_exists(
      index(:cart_items, [:subscription_plan_id], name: "cart_items_subscription_plan_id_index")
    )

    drop_if_exists(
      unique_index(:cart_items, [:cart_id, :variant_id, :subscription_plan_id],
        where: "subscription_plan_id IS NOT NULL",
        name: "cart_items_unique_cart_variant_plan_index"
      )
    )

    drop_if_exists(
      unique_index(:cart_items, [:cart_id, :variant_id],
        where: "subscription_plan_id IS NULL",
        name: "cart_items_unique_cart_variant_no_plan_index"
      )
    )

    create(
      unique_index(:cart_items, [:cart_id, :variant_id],
        name: "cart_items_unique_cart_variant_index"
      )
    )

    alter table(:cart_items) do
      remove(:subscription_plan_id)
    end

    drop_if_exists(
      index(:variant_subscription_plans, [:active],
        name: "variant_subscription_plans_active_index"
      )
    )

    drop_if_exists(
      index(:variant_subscription_plans, [:subscription_plan_id],
        name: "variant_subscription_plans_plan_id_index"
      )
    )

    drop_if_exists(
      unique_index(:variant_subscription_plans, [:variant_id],
        where: "active = true",
        name: "variant_subscription_plans_unique_active_variant_index"
      )
    )

    drop_if_exists(
      unique_index(:variant_subscription_plans, [:variant_id, :subscription_plan_id],
        name: "variant_subscription_plans_unique_variant_plan_index"
      )
    )

    drop(table(:variant_subscription_plans))

    drop(constraint(:subscription_plans, "subscription_plans_retry_schedule_not_empty_check"))
    drop(constraint(:subscription_plans, "subscription_plans_term_end_requirement_check"))
    drop(constraint(:subscription_plans, "subscription_plans_term_cycles_requirement_check"))
    drop(constraint(:subscription_plans, "subscription_plans_anchor_day_requirement_check"))
    drop(constraint(:subscription_plans, "subscription_plans_amount_minor_non_negative_check"))
    drop(constraint(:subscription_plans, "subscription_plans_interval_count_check"))
    drop(constraint(:subscription_plans, "subscription_plans_access_on_cancel_value_check"))
    drop(constraint(:subscription_plans, "subscription_plans_access_on_past_due_value_check"))
    drop(constraint(:subscription_plans, "subscription_plans_term_mode_value_check"))
    drop(constraint(:subscription_plans, "subscription_plans_anchor_mode_value_check"))
    drop(constraint(:subscription_plans, "subscription_plans_interval_unit_value_check"))
    drop(constraint(:subscription_plans, "subscription_plans_status_value_check"))

    drop_if_exists(
      index(:subscription_plans, [:interval_unit, :interval_count],
        name: "subscription_plans_interval_index"
      )
    )

    drop_if_exists(index(:subscription_plans, [:status], name: "subscription_plans_status_index"))

    drop_if_exists(
      unique_index(:subscription_plans, [:key], name: "subscription_plans_unique_key_index")
    )

    drop(table(:subscription_plans))

    drop(constraint(:products, "products_product_kind_value_check"))
    drop_if_exists(index(:products, [:product_kind], name: "products_product_kind_index"))

    alter table(:products) do
      remove(:product_kind)
    end
  end
end
