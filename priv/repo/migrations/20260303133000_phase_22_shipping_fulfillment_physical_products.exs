defmodule Store.Repo.Migrations.Phase22ShippingFulfillmentPhysicalProducts do
  @moduledoc """
  Adds shipping method/rule support, checkout quote evidence, and fulfillment resources.
  """

  use Ecto.Migration

  def up do
    create table(:shipping_methods, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :code, :text, null: false
      add :name, :text, null: false
      add :active, :boolean, null: false, default: true
      add :sort_order, :bigint, null: false, default: 100
      add :requires_address, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:shipping_methods, [:code], name: "shipping_methods_unique_code_index")
    create index(:shipping_methods, [:active], name: "shipping_methods_active_index")
    create index(:shipping_methods, [:sort_order], name: "shipping_methods_sort_order_index")

    alter table(:shipping_rates) do
      add :shipping_method_id,
          references(:shipping_methods,
            type: :uuid,
            name: "shipping_rates_shipping_method_id_fkey",
            on_delete: :nothing
          )
    end

    execute("""
    INSERT INTO shipping_methods (id, code, name, active, sort_order, requires_address, inserted_at, updated_at)
    VALUES (uuid_generate_v7(), 'STANDARD', 'Standard Shipping', true, 100, true,
            (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc'))
    ON CONFLICT (code) DO NOTHING
    """)

    execute("""
    UPDATE shipping_rates
    SET shipping_method_id = sm.id
    FROM shipping_methods sm
    WHERE sm.code = 'STANDARD' AND shipping_rates.shipping_method_id IS NULL
    """)

    execute("ALTER TABLE shipping_rates ALTER COLUMN shipping_method_id SET NOT NULL")

    create index(:shipping_rates, [:shipping_zone_id, :shipping_method_id, :active],
             name: "shipping_rates_zone_method_active_index"
           )

    create index(:shipping_rates, [:shipping_zone_id, :active],
             name: "shipping_rates_zone_active_index"
           )

    alter table(:orders) do
      add :shipping_quote_hash, :text
      add :shipping_quote_currency_code, :text
      add :shipping_quote_amount_minor, :bigint, null: false, default: 0
      add :shipping_weight_grams, :bigint, null: false, default: 0
      add :shipping_method_code, :text
      add :shipping_rule_id, :uuid
      add :shipping_zone_id, :uuid
      add :shipping_effective_from, :utc_datetime_usec
      add :shipping_effective_to, :utc_datetime_usec
    end

    create index(:orders, [:shipping_quote_hash], name: "orders_shipping_quote_hash_index")
    create index(:orders, [:shipping_rule_id], name: "orders_shipping_rule_id_index")
    create index(:orders, [:shipping_zone_id], name: "orders_shipping_zone_id_index")

    create constraint(:orders, "orders_shipping_quote_amount_minor_non_negative",
             check: "shipping_quote_amount_minor >= 0"
           )

    create constraint(:orders, "orders_shipping_weight_grams_non_negative",
             check: "shipping_weight_grams >= 0"
           )

    alter table(:variants) do
      add :weight_grams, :bigint, null: false, default: 0
    end

    create constraint(:variants, "variants_weight_grams_non_negative", check: "weight_grams >= 0")

    alter table(:order_line_items) do
      add :variant_id_snapshot, :uuid
    end

    create index(:order_line_items, [:variant_id_snapshot],
             name: "order_line_items_variant_id_snapshot_index"
           )

    create unique_index(:order_adjustments, [:order_id],
             where: "kind = 'shipping'",
             name: "order_adjustments_unique_shipping_per_order_index"
           )

    create table(:fulfillment_orders, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            type: :uuid,
            name: "fulfillment_orders_order_id_fkey",
            on_delete: :nothing
          ),
          null: false

      add :state, :text, null: false, default: "pending"
      add :shipping_method_code, :text, null: false
      add :shipping_address_snapshot, :map, null: false, default: %{}
      add :notes, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:fulfillment_orders, [:order_id],
             name: "fulfillment_orders_unique_order_id_index"
           )

    create index(:fulfillment_orders, [:state, :inserted_at],
             name: "fulfillment_orders_state_inserted_at_index"
           )

    create constraint(:fulfillment_orders, "fulfillment_orders_state_check",
             check: "state IN ('pending','packed','shipped','delivered','canceled')"
           )

    create table(:shipments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :fulfillment_order_id,
          references(:fulfillment_orders,
            type: :uuid,
            name: "shipments_fulfillment_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :state, :text, null: false, default: "created"
      add :carrier, :text
      add :tracking_ref, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:shipments, [:fulfillment_order_id],
             name: "shipments_fulfillment_order_id_index"
           )

    create index(:shipments, [:state, :inserted_at], name: "shipments_state_inserted_at_index")

    create unique_index(:shipments, [:tracking_ref],
             where: "tracking_ref IS NOT NULL",
             name: "shipments_unique_tracking_ref_index"
           )

    create constraint(:shipments, "shipments_state_check",
             check: "state IN ('created','in_transit','delivered','canceled')"
           )

    create table(:fulfillment_items, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :fulfillment_order_id,
          references(:fulfillment_orders,
            type: :uuid,
            name: "fulfillment_items_fulfillment_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :order_line_item_id,
          references(:order_line_items,
            type: :uuid,
            name: "fulfillment_items_order_line_item_id_fkey",
            on_delete: :nothing
          ),
          null: false

      add :variant_id, :uuid
      add :quantity, :bigint, null: false
      add :product_title_snapshot, :text
      add :variant_title_snapshot, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:fulfillment_items, [:fulfillment_order_id, :order_line_item_id],
             name: "fulfillment_items_unique_order_line_item_index"
           )

    create index(:fulfillment_items, [:variant_id], name: "fulfillment_items_variant_id_index")

    create constraint(:fulfillment_items, "fulfillment_items_quantity_positive",
             check: "quantity > 0"
           )
  end

  def down do
    drop constraint(:fulfillment_items, "fulfillment_items_quantity_positive")

    drop_if_exists index(:fulfillment_items, [:variant_id],
                     name: "fulfillment_items_variant_id_index"
                   )

    drop_if_exists unique_index(:fulfillment_items, [:fulfillment_order_id, :order_line_item_id],
                     name: "fulfillment_items_unique_order_line_item_index"
                   )

    drop table(:fulfillment_items)

    drop constraint(:shipments, "shipments_state_check")

    drop_if_exists unique_index(:shipments, [:tracking_ref],
                     where: "tracking_ref IS NOT NULL",
                     name: "shipments_unique_tracking_ref_index"
                   )

    drop_if_exists index(:shipments, [:state, :inserted_at],
                     name: "shipments_state_inserted_at_index"
                   )

    drop_if_exists index(:shipments, [:fulfillment_order_id],
                     name: "shipments_fulfillment_order_id_index"
                   )

    drop table(:shipments)

    drop constraint(:fulfillment_orders, "fulfillment_orders_state_check")

    drop_if_exists index(:fulfillment_orders, [:state, :inserted_at],
                     name: "fulfillment_orders_state_inserted_at_index"
                   )

    drop_if_exists unique_index(:fulfillment_orders, [:order_id],
                     name: "fulfillment_orders_unique_order_id_index"
                   )

    drop table(:fulfillment_orders)

    drop_if_exists unique_index(:order_adjustments, [:order_id],
                     where: "kind = 'shipping'",
                     name: "order_adjustments_unique_shipping_per_order_index"
                   )

    drop constraint(:variants, "variants_weight_grams_non_negative")

    alter table(:variants) do
      remove :weight_grams
    end

    drop_if_exists index(:order_line_items, [:variant_id_snapshot],
                     name: "order_line_items_variant_id_snapshot_index"
                   )

    alter table(:order_line_items) do
      remove :variant_id_snapshot
    end

    drop constraint(:orders, "orders_shipping_weight_grams_non_negative")
    drop constraint(:orders, "orders_shipping_quote_amount_minor_non_negative")
    drop_if_exists index(:orders, [:shipping_zone_id], name: "orders_shipping_zone_id_index")
    drop_if_exists index(:orders, [:shipping_rule_id], name: "orders_shipping_rule_id_index")

    drop_if_exists index(:orders, [:shipping_quote_hash],
                     name: "orders_shipping_quote_hash_index"
                   )

    alter table(:orders) do
      remove :shipping_effective_to
      remove :shipping_effective_from
      remove :shipping_zone_id
      remove :shipping_rule_id
      remove :shipping_method_code
      remove :shipping_weight_grams
      remove :shipping_quote_amount_minor
      remove :shipping_quote_currency_code
      remove :shipping_quote_hash
    end

    drop_if_exists index(:shipping_rates, [:shipping_zone_id, :active],
                     name: "shipping_rates_zone_active_index"
                   )

    drop_if_exists index(:shipping_rates, [:shipping_zone_id, :shipping_method_id, :active],
                     name: "shipping_rates_zone_method_active_index"
                   )

    execute("ALTER TABLE shipping_rates ALTER COLUMN shipping_method_id DROP NOT NULL")

    alter table(:shipping_rates) do
      remove :shipping_method_id
    end

    drop_if_exists index(:shipping_methods, [:sort_order],
                     name: "shipping_methods_sort_order_index"
                   )

    drop_if_exists index(:shipping_methods, [:active], name: "shipping_methods_active_index")

    drop_if_exists unique_index(:shipping_methods, [:code],
                     name: "shipping_methods_unique_code_index"
                   )

    drop table(:shipping_methods)
  end
end
