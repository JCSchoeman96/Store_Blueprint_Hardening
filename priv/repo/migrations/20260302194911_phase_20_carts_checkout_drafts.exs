defmodule Store.Repo.Migrations.Phase20CartsCheckoutDrafts do
  @moduledoc """
  Adds persistent carts and checkout drafts for Phase 20 storefront/cart UX.
  """

  use Ecto.Migration

  def up do
    create table(:carts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :token, :text, null: false
      add :user_id, :uuid
      add :status, :text, null: false, default: "active"
      add :merged_into_cart_id, :uuid
      add :version, :integer, null: false, default: 1

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    execute("""
    ALTER TABLE carts
    ADD CONSTRAINT carts_merged_into_cart_id_fkey
    FOREIGN KEY (merged_into_cart_id)
    REFERENCES carts(id)
    ON DELETE SET NULL
    """)

    create index(:carts, [:user_id], name: "carts_user_id_index")
    create index(:carts, [:status], name: "carts_status_index")
    create index(:carts, [:merged_into_cart_id], name: "carts_merged_into_cart_id_index")

    create unique_index(:carts, [:token],
             where: "status = 'active'",
             name: "carts_unique_active_token_index"
           )

    create unique_index(:carts, [:user_id],
             where: "status = 'active' AND user_id IS NOT NULL",
             name: "carts_unique_active_user_id_index"
           )

    create constraint(
             :carts,
             "carts_status_value_check",
             check: "status IN ('active', 'abandoned')"
           )

    create constraint(
             :carts,
             "carts_version_positive_check",
             check: "version >= 1"
           )

    create table(:cart_items, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :cart_id,
          references(:carts,
            column: :id,
            type: :uuid,
            name: "cart_items_cart_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :variant_id,
          references(:variants,
            column: :id,
            type: :uuid,
            name: "cart_items_variant_id_fkey",
            on_delete: :restrict
          ),
          null: false

      add :qty, :integer, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:cart_items, [:cart_id], name: "cart_items_cart_id_index")
    create index(:cart_items, [:variant_id], name: "cart_items_variant_id_index")

    create unique_index(:cart_items, [:cart_id, :variant_id],
             name: "cart_items_unique_cart_variant_index"
           )

    create constraint(
             :cart_items,
             "cart_items_qty_range_check",
             check: "qty >= 1 AND qty <= 99"
           )

    create table(:checkout_drafts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :checkout_key, :text, null: false

      add :cart_id,
          references(:carts,
            column: :id,
            type: :uuid,
            name: "checkout_drafts_cart_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :cart_version, :integer, null: false
      add :user_id, :uuid
      add :status, :text, null: false, default: "open"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:checkout_drafts, [:cart_id], name: "checkout_drafts_cart_id_index")
    create index(:checkout_drafts, [:user_id], name: "checkout_drafts_user_id_index")
    create index(:checkout_drafts, [:status], name: "checkout_drafts_status_index")

    create unique_index(:checkout_drafts, [:checkout_key],
             name: "checkout_drafts_unique_checkout_key_index"
           )

    create unique_index(:checkout_drafts, [:cart_id, :cart_version],
             name: "checkout_drafts_unique_cart_id_cart_version_index"
           )

    create constraint(
             :checkout_drafts,
             "checkout_drafts_status_value_check",
             check: "status IN ('open', 'consumed', 'expired')"
           )

    create constraint(
             :checkout_drafts,
             "checkout_drafts_cart_version_positive_check",
             check: "cart_version >= 1"
           )
  end

  def down do
    drop constraint(:checkout_drafts, "checkout_drafts_cart_version_positive_check")
    drop constraint(:checkout_drafts, "checkout_drafts_status_value_check")

    drop_if_exists unique_index(:checkout_drafts, [:cart_id, :cart_version],
                     name: "checkout_drafts_unique_cart_id_cart_version_index"
                   )

    drop_if_exists unique_index(:checkout_drafts, [:checkout_key],
                     name: "checkout_drafts_unique_checkout_key_index"
                   )

    drop_if_exists index(:checkout_drafts, [:status], name: "checkout_drafts_status_index")
    drop_if_exists index(:checkout_drafts, [:user_id], name: "checkout_drafts_user_id_index")
    drop_if_exists index(:checkout_drafts, [:cart_id], name: "checkout_drafts_cart_id_index")
    drop table(:checkout_drafts)

    drop constraint(:cart_items, "cart_items_qty_range_check")

    drop_if_exists unique_index(:cart_items, [:cart_id, :variant_id],
                     name: "cart_items_unique_cart_variant_index"
                   )

    drop_if_exists index(:cart_items, [:variant_id], name: "cart_items_variant_id_index")
    drop_if_exists index(:cart_items, [:cart_id], name: "cart_items_cart_id_index")
    drop table(:cart_items)

    drop constraint(:carts, "carts_version_positive_check")
    drop constraint(:carts, "carts_status_value_check")
    drop constraint(:carts, "carts_merged_into_cart_id_fkey")

    drop_if_exists unique_index(:carts, [:user_id],
                     where: "status = 'active' AND user_id IS NOT NULL",
                     name: "carts_unique_active_user_id_index"
                   )

    drop_if_exists unique_index(:carts, [:token],
                     where: "status = 'active'",
                     name: "carts_unique_active_token_index"
                   )

    drop_if_exists index(:carts, [:merged_into_cart_id], name: "carts_merged_into_cart_id_index")
    drop_if_exists index(:carts, [:status], name: "carts_status_index")
    drop_if_exists index(:carts, [:user_id], name: "carts_user_id_index")
    drop table(:carts)
  end
end
