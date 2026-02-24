defmodule Store.Repo.Migrations.Phase11InventoryReservations do
  @moduledoc """
  Adds inventory_items and inventory_reservations for strict no-oversell behavior.
  """

  use Ecto.Migration

  def up do
    create table(:inventory_items, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :variant_id, :uuid, null: false
      add :stock_on_hand, :bigint, null: false, default: 0
      add :reserved_count, :bigint, null: false, default: 0
      add :allow_oversell, :boolean, null: false, default: false
      add :version, :bigint, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:inventory_items, [:variant_id],
             name: "inventory_items_unique_variant_id_index"
           )

    create index(:inventory_items, [:allow_oversell],
             name: "inventory_items_allow_oversell_index"
           )

    create constraint(
             :inventory_items,
             "inventory_items_stock_on_hand_non_negative",
             check: "stock_on_hand >= 0"
           )

    create constraint(
             :inventory_items,
             "inventory_items_reserved_count_non_negative",
             check: "reserved_count >= 0"
           )

    create table(:inventory_reservations, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            column: :id,
            type: :uuid,
            name: "inventory_reservations_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :variant_id, :uuid, null: false
      add :reservation_key, :text, null: false
      add :quantity, :bigint, null: false
      add :state, :text, null: false, default: "active"
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :version, :bigint, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:inventory_reservations, [:order_id, :variant_id],
             name: "inventory_reservations_unique_order_variant_index"
           )

    create unique_index(:inventory_reservations, [:reservation_key],
             name: "inventory_reservations_unique_reservation_key_index"
           )

    create index(:inventory_reservations, [:order_id, :state],
             name: "inventory_reservations_order_state_index"
           )

    create index(:inventory_reservations, [:variant_id, :state],
             name: "inventory_reservations_variant_state_index"
           )

    create index(:inventory_reservations, [:state, :expires_at],
             name: "inventory_reservations_state_expires_at_index"
           )

    create index(:inventory_reservations, [:expires_at],
             where: "state = 'active'",
             name: "inventory_reservations_active_expires_at_index"
           )

    create constraint(
             :inventory_reservations,
             "inventory_reservations_quantity_non_negative",
             check: "quantity >= 0"
           )
  end

  def down do
    drop constraint(
           :inventory_reservations,
           "inventory_reservations_quantity_non_negative"
         )

    drop_if_exists index(:inventory_reservations, [:expires_at],
                     where: "state = 'active'",
                     name: "inventory_reservations_active_expires_at_index"
                   )

    drop_if_exists index(:inventory_reservations, [:state, :expires_at],
                     name: "inventory_reservations_state_expires_at_index"
                   )

    drop_if_exists index(:inventory_reservations, [:variant_id, :state],
                     name: "inventory_reservations_variant_state_index"
                   )

    drop_if_exists index(:inventory_reservations, [:order_id, :state],
                     name: "inventory_reservations_order_state_index"
                   )

    drop_if_exists unique_index(:inventory_reservations, [:reservation_key],
                     name: "inventory_reservations_unique_reservation_key_index"
                   )

    drop_if_exists unique_index(:inventory_reservations, [:order_id, :variant_id],
                     name: "inventory_reservations_unique_order_variant_index"
                   )

    drop table(:inventory_reservations)

    drop constraint(
           :inventory_items,
           "inventory_items_reserved_count_non_negative"
         )

    drop constraint(
           :inventory_items,
           "inventory_items_stock_on_hand_non_negative"
         )

    drop_if_exists index(:inventory_items, [:allow_oversell],
                     name: "inventory_items_allow_oversell_index"
                   )

    drop_if_exists unique_index(:inventory_items, [:variant_id],
                     name: "inventory_items_unique_variant_id_index"
                   )

    drop table(:inventory_items)
  end
end
