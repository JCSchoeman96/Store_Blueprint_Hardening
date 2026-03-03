defmodule Store.Repo.Migrations.Phase24DigitalProductsDownloadGrants do
  @moduledoc """
  Adds digital assets, product links, and download grants for phase-24.

  Option A pin:
  - `max_downloads` + `download_count` fields are present for forward compatibility.
  - max download enforcement is intentionally deferred and not encoded as a DB CHECK in this phase.
  """

  use Ecto.Migration

  def up do
    create table(:digital_assets, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :key, :text, null: false
      add :title, :text, null: false
      add :content_type, :text, null: false
      add :byte_size, :bigint, null: false, default: 0
      add :storage_provider, :text, null: false, default: "s3"
      add :storage_bucket, :text, null: false
      add :storage_object_key, :text, null: false
      add :checksum_sha256, :text
      add :status, :text, null: false, default: "active"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:digital_assets, [:key], name: "digital_assets_unique_key_index")

    create index(:digital_assets, [:status, :inserted_at],
             name: "digital_assets_status_inserted_at_index"
           )

    create constraint(:digital_assets, "digital_assets_status_check",
             check: "status IN ('active', 'archived')"
           )

    create table(:product_digital_links, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :product_id,
          references(:products,
            column: :id,
            type: :uuid,
            name: "product_digital_links_product_id_fkey",
            on_delete: :delete_all
          )

      add :variant_id,
          references(:variants,
            column: :id,
            type: :uuid,
            name: "product_digital_links_variant_id_fkey",
            on_delete: :delete_all
          )

      add :digital_asset_id,
          references(:digital_assets,
            column: :id,
            type: :uuid,
            name: "product_digital_links_digital_asset_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :position, :bigint, null: false, default: 0
      add :grant_expires_in_days, :bigint
      add :grant_max_downloads, :bigint

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:product_digital_links, [:digital_asset_id],
             name: "product_digital_links_digital_asset_id_index"
           )

    create index(:product_digital_links, [:product_id],
             name: "product_digital_links_product_id_index"
           )

    create index(:product_digital_links, [:variant_id],
             name: "product_digital_links_variant_id_index"
           )

    create index(:product_digital_links, [:product_id, :position, :id],
             name: "product_digital_links_product_position_index"
           )

    create index(:product_digital_links, [:variant_id, :position, :id],
             name: "product_digital_links_variant_position_index"
           )

    execute(
      """
      CREATE UNIQUE INDEX product_digital_links_unique_product_asset_index
      ON product_digital_links (product_id, digital_asset_id)
      WHERE product_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS product_digital_links_unique_product_asset_index"
    )

    execute(
      """
      CREATE UNIQUE INDEX product_digital_links_unique_variant_asset_index
      ON product_digital_links (variant_id, digital_asset_id)
      WHERE variant_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS product_digital_links_unique_variant_asset_index"
    )

    create constraint(:product_digital_links, "product_digital_links_exactly_one_target_check",
             check:
               "(product_id IS NOT NULL AND variant_id IS NULL) OR (product_id IS NULL AND variant_id IS NOT NULL)"
           )

    create constraint(:product_digital_links, "product_digital_links_position_non_negative_check",
             check: "position >= 0"
           )

    create constraint(
             :product_digital_links,
             "product_digital_links_grant_expires_positive_check",
             check: "grant_expires_in_days IS NULL OR grant_expires_in_days > 0"
           )

    create constraint(:product_digital_links, "product_digital_links_grant_max_positive_check",
             check: "grant_max_downloads IS NULL OR grant_max_downloads > 0"
           )

    create table(:download_grants, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id,
          references(:orders,
            column: :id,
            type: :uuid,
            name: "download_grants_order_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :order_line_item_id,
          references(:order_line_items,
            column: :id,
            type: :uuid,
            name: "download_grants_order_line_item_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :digital_asset_id,
          references(:digital_assets,
            column: :id,
            type: :uuid,
            name: "download_grants_digital_asset_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :actor_user_id,
          references(:users,
            column: :id,
            type: :uuid,
            name: "download_grants_actor_user_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :status, :text, null: false, default: "active"

      add :issued_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :expires_at, :utc_datetime_usec
      add :max_downloads, :bigint
      add :download_count, :bigint, null: false, default: 0
      add :revoked_reason, :text
      add :idempotency_key, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:download_grants, [:order_line_item_id, :digital_asset_id],
             name: "download_grants_unique_order_line_item_asset_index"
           )

    create index(:download_grants, [:actor_user_id], name: "download_grants_actor_user_id_index")
    create index(:download_grants, [:order_id], name: "download_grants_order_id_index")
    create index(:download_grants, [:expires_at], name: "download_grants_expires_at_index")

    create index(:download_grants, [:digital_asset_id],
             name: "download_grants_digital_asset_id_index"
           )

    create index(:download_grants, [:status, :inserted_at],
             name: "download_grants_status_inserted_at_index"
           )

    create index(:download_grants, [:idempotency_key],
             name: "download_grants_idempotency_key_index"
           )

    create constraint(:download_grants, "download_grants_status_check",
             check: "status IN ('active', 'revoked', 'expired')"
           )

    create constraint(:download_grants, "download_grants_max_downloads_positive_check",
             check: "max_downloads IS NULL OR max_downloads > 0"
           )

    create constraint(:download_grants, "download_grants_download_count_non_negative_check",
             check: "download_count >= 0"
           )
  end

  def down do
    drop constraint(:download_grants, "download_grants_download_count_non_negative_check")
    drop constraint(:download_grants, "download_grants_max_downloads_positive_check")
    drop constraint(:download_grants, "download_grants_status_check")

    drop_if_exists index(:download_grants, [:idempotency_key],
                     name: "download_grants_idempotency_key_index"
                   )

    drop_if_exists index(:download_grants, [:status, :inserted_at],
                     name: "download_grants_status_inserted_at_index"
                   )

    drop_if_exists index(:download_grants, [:digital_asset_id],
                     name: "download_grants_digital_asset_id_index"
                   )

    drop_if_exists index(:download_grants, [:expires_at],
                     name: "download_grants_expires_at_index"
                   )

    drop_if_exists index(:download_grants, [:order_id], name: "download_grants_order_id_index")

    drop_if_exists index(:download_grants, [:actor_user_id],
                     name: "download_grants_actor_user_id_index"
                   )

    drop_if_exists unique_index(:download_grants, [:order_line_item_id, :digital_asset_id],
                     name: "download_grants_unique_order_line_item_asset_index"
                   )

    drop table(:download_grants)

    drop constraint(:product_digital_links, "product_digital_links_grant_max_positive_check")
    drop constraint(:product_digital_links, "product_digital_links_grant_expires_positive_check")
    drop constraint(:product_digital_links, "product_digital_links_position_non_negative_check")
    drop constraint(:product_digital_links, "product_digital_links_exactly_one_target_check")

    execute("DROP INDEX IF EXISTS product_digital_links_unique_variant_asset_index")
    execute("DROP INDEX IF EXISTS product_digital_links_unique_product_asset_index")

    drop_if_exists index(:product_digital_links, [:variant_id, :position, :id],
                     name: "product_digital_links_variant_position_index"
                   )

    drop_if_exists index(:product_digital_links, [:product_id, :position, :id],
                     name: "product_digital_links_product_position_index"
                   )

    drop_if_exists index(:product_digital_links, [:variant_id],
                     name: "product_digital_links_variant_id_index"
                   )

    drop_if_exists index(:product_digital_links, [:product_id],
                     name: "product_digital_links_product_id_index"
                   )

    drop_if_exists index(:product_digital_links, [:digital_asset_id],
                     name: "product_digital_links_digital_asset_id_index"
                   )

    drop table(:product_digital_links)

    drop constraint(:digital_assets, "digital_assets_status_check")

    drop_if_exists index(:digital_assets, [:status, :inserted_at],
                     name: "digital_assets_status_inserted_at_index"
                   )

    drop_if_exists unique_index(:digital_assets, [:key], name: "digital_assets_unique_key_index")
    drop table(:digital_assets)
  end
end
