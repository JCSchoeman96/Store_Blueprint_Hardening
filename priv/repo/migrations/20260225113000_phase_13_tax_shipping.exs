defmodule Store.Repo.Migrations.Phase13TaxShipping do
  @moduledoc """
  Adds deterministic shipping/tax definition tables and order snapshot evidence fields.
  """

  use Ecto.Migration

  def up do
    create table(:shipping_zones, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :code, :text, null: false
      add :country_code, :text, null: false
      add :region_code, :text
      add :active, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:shipping_zones, [:code], name: "shipping_zones_unique_code_index")
    create index(:shipping_zones, [:active], name: "shipping_zones_active_index")

    create index(:shipping_zones, [:country_code, :region_code],
             name: "shipping_zones_country_region_index"
           )

    create table(:shipping_rates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :code, :text, null: false
      add :currency, :text, null: false

      add :shipping_zone_id,
          references(:shipping_zones,
            type: :uuid,
            name: "shipping_rates_shipping_zone_id_fkey",
            on_delete: :nothing
          )

      add :shipping_cost_minor, :bigint, null: false, default: 0
      add :weight_min_grams, :bigint
      add :weight_max_grams, :bigint
      add :free_over_subtotal_minor, :bigint
      add :allow_free_shipping_coupon, :boolean, null: false, default: false
      add :active, :boolean, null: false, default: true
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :precedence_rank, :bigint, null: false, default: 100

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:shipping_rates, [:code], name: "shipping_rates_unique_code_index")

    create index(:shipping_rates, [:currency, :active],
             name: "shipping_rates_currency_active_index"
           )

    create index(:shipping_rates, [:starts_at, :ends_at], name: "shipping_rates_window_index")

    create index(:shipping_rates, [:shipping_zone_id],
             name: "shipping_rates_shipping_zone_id_index"
           )

    create constraint(:shipping_rates, "shipping_rates_shipping_cost_minor_non_negative",
             check: "shipping_cost_minor >= 0"
           )

    create constraint(:shipping_rates, "shipping_rates_weight_min_non_negative",
             check: "weight_min_grams IS NULL OR weight_min_grams >= 0"
           )

    create constraint(:shipping_rates, "shipping_rates_weight_max_non_negative",
             check: "weight_max_grams IS NULL OR weight_max_grams >= 0"
           )

    create constraint(:shipping_rates, "shipping_rates_weight_bounds_valid",
             check:
               "weight_min_grams IS NULL OR weight_max_grams IS NULL OR weight_min_grams <= weight_max_grams"
           )

    create constraint(:shipping_rates, "shipping_rates_free_threshold_non_negative",
             check: "free_over_subtotal_minor IS NULL OR free_over_subtotal_minor >= 0"
           )

    create table(:tax_rates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :code, :text, null: false
      add :country_code, :text, null: false
      add :region_code, :text
      add :product_tax_category, :text
      add :rate_basis_points, :bigint, null: false
      add :shipping_taxable, :boolean, null: false, default: true
      add :active, :boolean, null: false, default: true
      add :starts_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :precedence_rank, :bigint, null: false, default: 100

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:tax_rates, [:code], name: "tax_rates_unique_code_index")

    create index(:tax_rates, [:country_code, :region_code],
             name: "tax_rates_country_region_index"
           )

    create index(:tax_rates, [:product_tax_category],
             name: "tax_rates_product_tax_category_index"
           )

    create index(:tax_rates, [:active], name: "tax_rates_active_index")
    create index(:tax_rates, [:starts_at, :ends_at], name: "tax_rates_window_index")

    create constraint(:tax_rates, "tax_rates_rate_basis_points_non_negative",
             check: "rate_basis_points >= 0"
           )

    alter table(:orders) do
      add :shipping_rate_id, :uuid
      add :shipping_rate_code, :text
      add :shipping_cost_minor_original, :bigint, null: false, default: 0
      add :shipping_cost_minor_effective, :bigint, null: false, default: 0
      add :free_shipping_applied, :boolean, null: false, default: false
      add :free_shipping_reason, :text
      add :shipping_tax_minor, :bigint, null: false, default: 0
      add :tax_total_minor, :bigint, null: false, default: 0
      add :shipping_country_code, :text
      add :shipping_region_code, :text
      add :shipping_postal_code, :text
      add :tax_as_of, :utc_datetime_usec
    end

    create index(:orders, [:shipping_rate_id], name: "orders_shipping_rate_id_index")
    create index(:orders, [:tax_as_of], name: "orders_tax_as_of_index")

    create constraint(:orders, "orders_shipping_cost_minor_original_non_negative",
             check: "shipping_cost_minor_original >= 0"
           )

    create constraint(:orders, "orders_shipping_cost_minor_effective_non_negative",
             check: "shipping_cost_minor_effective >= 0"
           )

    create constraint(:orders, "orders_shipping_tax_minor_non_negative",
             check: "shipping_tax_minor >= 0"
           )

    create constraint(:orders, "orders_tax_total_minor_non_negative",
             check: "tax_total_minor >= 0"
           )

    alter table(:order_line_items) do
      add :tax_category_snapshot, :text, null: false, default: "STANDARD"
      add :tax_rate_id_snapshot, :uuid
      add :tax_rate_code_snapshot, :text
      add :tax_rate_bps_snapshot, :bigint
      add :tax_minor, :bigint, null: false, default: 0
    end

    create index(:order_line_items, [:tax_rate_id_snapshot],
             name: "order_line_items_tax_rate_id_snapshot_index"
           )

    create constraint(:order_line_items, "order_line_items_tax_minor_non_negative",
             check: "tax_minor >= 0"
           )
  end

  def down do
    drop_if_exists constraint(:order_line_items, "order_line_items_tax_minor_non_negative")

    drop_if_exists index(:order_line_items, [:tax_rate_id_snapshot],
                     name: "order_line_items_tax_rate_id_snapshot_index"
                   )

    alter table(:order_line_items) do
      remove :tax_minor
      remove :tax_rate_bps_snapshot
      remove :tax_rate_code_snapshot
      remove :tax_rate_id_snapshot
      remove :tax_category_snapshot
    end

    drop_if_exists constraint(:orders, "orders_tax_total_minor_non_negative")
    drop_if_exists constraint(:orders, "orders_shipping_tax_minor_non_negative")
    drop_if_exists constraint(:orders, "orders_shipping_cost_minor_effective_non_negative")
    drop_if_exists constraint(:orders, "orders_shipping_cost_minor_original_non_negative")
    drop_if_exists index(:orders, [:tax_as_of], name: "orders_tax_as_of_index")
    drop_if_exists index(:orders, [:shipping_rate_id], name: "orders_shipping_rate_id_index")

    alter table(:orders) do
      remove :tax_as_of
      remove :shipping_postal_code
      remove :shipping_region_code
      remove :shipping_country_code
      remove :tax_total_minor
      remove :shipping_tax_minor
      remove :free_shipping_reason
      remove :free_shipping_applied
      remove :shipping_cost_minor_effective
      remove :shipping_cost_minor_original
      remove :shipping_rate_code
      remove :shipping_rate_id
    end

    drop_if_exists constraint(:tax_rates, "tax_rates_rate_basis_points_non_negative")
    drop_if_exists index(:tax_rates, [:starts_at, :ends_at], name: "tax_rates_window_index")
    drop_if_exists index(:tax_rates, [:active], name: "tax_rates_active_index")

    drop_if_exists index(:tax_rates, [:product_tax_category],
                     name: "tax_rates_product_tax_category_index"
                   )

    drop_if_exists index(:tax_rates, [:country_code, :region_code],
                     name: "tax_rates_country_region_index"
                   )

    drop_if_exists unique_index(:tax_rates, [:code], name: "tax_rates_unique_code_index")
    drop table(:tax_rates)

    drop_if_exists constraint(:shipping_rates, "shipping_rates_free_threshold_non_negative")
    drop_if_exists constraint(:shipping_rates, "shipping_rates_weight_bounds_valid")
    drop_if_exists constraint(:shipping_rates, "shipping_rates_weight_max_non_negative")
    drop_if_exists constraint(:shipping_rates, "shipping_rates_weight_min_non_negative")

    drop_if_exists constraint(
                     :shipping_rates,
                     "shipping_rates_shipping_cost_minor_non_negative"
                   )

    drop_if_exists index(:shipping_rates, [:shipping_zone_id],
                     name: "shipping_rates_shipping_zone_id_index"
                   )

    drop_if_exists index(:shipping_rates, [:starts_at, :ends_at],
                     name: "shipping_rates_window_index"
                   )

    drop_if_exists index(:shipping_rates, [:currency, :active],
                     name: "shipping_rates_currency_active_index"
                   )

    drop_if_exists unique_index(:shipping_rates, [:code],
                     name: "shipping_rates_unique_code_index"
                   )

    drop table(:shipping_rates)

    drop_if_exists index(:shipping_zones, [:country_code, :region_code],
                     name: "shipping_zones_country_region_index"
                   )

    drop_if_exists index(:shipping_zones, [:active], name: "shipping_zones_active_index")

    drop_if_exists unique_index(:shipping_zones, [:code],
                     name: "shipping_zones_unique_code_index"
                   )

    drop table(:shipping_zones)
  end
end
