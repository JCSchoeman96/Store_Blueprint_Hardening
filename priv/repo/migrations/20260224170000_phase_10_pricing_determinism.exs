defmodule Store.Repo.Migrations.Phase10PricingDeterminism do
  @moduledoc """
  Adds deterministic pricing definitions and immutable snapshot evidence fields.
  """

  use Ecto.Migration

  def up do
    create table(:coupons, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(:code, :text, null: false)
      add(:currency, :text, null: false)
      add(:discount_minor, :bigint, null: false)
      add(:starts_at, :utc_datetime_usec)
      add(:ends_at, :utc_datetime_usec)
      add(:active, :boolean, null: false, default: true)
      add(:combinable_with_promotions, :boolean, null: false, default: true)
      add(:allow_with_exclusive, :boolean, null: false, default: false)
      add(:precedence_rank, :bigint, null: false, default: 100)
      add(:eligibility_key, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:coupons, [:code], name: "coupons_unique_code_index"))
    create(index(:coupons, [:active], name: "coupons_active_index"))
    create(index(:coupons, [:starts_at, :ends_at], name: "coupons_window_index"))

    create table(:promotions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(:code, :text, null: false)
      add(:currency, :text, null: false)
      add(:discount_minor, :bigint, null: false)
      add(:starts_at, :utc_datetime_usec)
      add(:ends_at, :utc_datetime_usec)
      add(:active, :boolean, null: false, default: true)
      add(:exclusive, :boolean, null: false, default: false)
      add(:combinable, :boolean, null: false, default: true)
      add(:exclusive_priority, :bigint, null: false, default: 0)
      add(:precedence_rank, :bigint, null: false, default: 200)
      add(:eligibility_key, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:promotions, [:code], name: "promotions_unique_code_index"))
    create(index(:promotions, [:active], name: "promotions_active_index"))
    create(index(:promotions, [:starts_at, :ends_at], name: "promotions_window_index"))

    create(
      index(:promotions, [:exclusive, :exclusive_priority],
        name: "promotions_exclusive_priority_index"
      )
    )

    alter table(:order_line_items) do
      add(:sku_snapshot, :text, null: false, default: "")
      add(:product_title_snapshot, :text, null: false, default: "")
      add(:variant_title_snapshot, :text)
      add(:discount_allocated_minor, :bigint, null: false, default: 0)
      add(:net_line_total_minor, :bigint, null: false, default: 0)
    end

    alter table(:order_adjustments) do
      add(:source_kind, :text)
      add(:source_code, :text)
      add(:source_id, :uuid)
      add(:precedence_rank, :bigint, null: false, default: 0)
    end

    create(index(:order_adjustments, [:source_id], name: "order_adjustments_source_id_index"))
  end

  def down do
    drop_if_exists(
      index(:order_adjustments, [:source_id], name: "order_adjustments_source_id_index")
    )

    alter table(:order_adjustments) do
      remove(:source_kind)
      remove(:source_code)
      remove(:source_id)
      remove(:precedence_rank)
    end

    alter table(:order_line_items) do
      remove(:sku_snapshot)
      remove(:product_title_snapshot)
      remove(:variant_title_snapshot)
      remove(:discount_allocated_minor)
      remove(:net_line_total_minor)
    end

    drop_if_exists(
      index(:promotions, [:exclusive, :exclusive_priority],
        name: "promotions_exclusive_priority_index"
      )
    )

    drop_if_exists(index(:promotions, [:starts_at, :ends_at], name: "promotions_window_index"))
    drop_if_exists(index(:promotions, [:active], name: "promotions_active_index"))
    drop_if_exists(unique_index(:promotions, [:code], name: "promotions_unique_code_index"))
    drop(table(:promotions))

    drop_if_exists(index(:coupons, [:starts_at, :ends_at], name: "coupons_window_index"))
    drop_if_exists(index(:coupons, [:active], name: "coupons_active_index"))
    drop_if_exists(unique_index(:coupons, [:code], name: "coupons_unique_code_index"))
    drop(table(:coupons))
  end
end
