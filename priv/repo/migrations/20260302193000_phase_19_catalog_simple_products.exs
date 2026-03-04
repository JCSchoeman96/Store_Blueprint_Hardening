defmodule Store.Repo.Migrations.Phase19CatalogSimpleProducts do
  @moduledoc """
  Adds catalog product resources with variant-first identity for simple products.
  """

  use Ecto.Migration

  def up do
    create table(:catalog_categories, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :slug, :text, null: false
      add :name, :text, null: false
      add :position, :bigint, null: false, default: 0
      add :is_active, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:catalog_categories, [:slug],
             name: "catalog_categories_unique_slug_index"
           )

    create table(:products, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :slug, :text, null: false
      add :title, :text, null: false
      add :subtitle, :text
      add :description, :text
      add :status, :text, null: false, default: "draft"
      add :published_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec
      add :default_variant_id, :uuid, null: false

      add :category_id,
          references(:catalog_categories,
            column: :id,
            type: :uuid,
            name: "products_category_id_fkey",
            on_delete: :nilify_all
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:products, [:slug], name: "products_unique_slug_index")
    create index(:products, [:category_id], name: "products_category_id_index")
    create index(:products, [:status], name: "products_status_index")
    create index(:products, [:published_at], name: "products_published_at_index")

    create constraint(
             :products,
             "products_status_value_check",
             check: "status IN ('draft', 'published', 'archived')"
           )

    create constraint(
             :products,
             "products_published_requires_published_at",
             check: "(status <> 'published') OR (published_at IS NOT NULL)"
           )

    create table(:variants, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :product_id,
          references(:products,
            column: :id,
            type: :uuid,
            name: "variants_product_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :is_default, :boolean, null: false, default: false
      add :sku, :text, null: false
      add :title, :text
      add :currency_code, :text, null: false
      add :price_minor, :bigint, null: false
      add :compare_at_price_minor, :bigint
      add :status, :text, null: false, default: "active"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:variants, [:sku], name: "variants_unique_sku_index")
    create index(:variants, [:product_id], name: "variants_product_id_index")

    create unique_index(:variants, [:product_id],
             where: "is_default = true",
             name: "variants_unique_default_per_product_index"
           )

    create constraint(
             :variants,
             "variants_status_value_check",
             check: "status IN ('active', 'archived')"
           )

    create constraint(
             :variants,
             "variants_price_minor_non_negative",
             check: "price_minor >= 0"
           )

    create constraint(
             :variants,
             "variants_compare_at_price_minor_non_negative",
             check: "compare_at_price_minor IS NULL OR compare_at_price_minor >= 0"
           )

    execute("""
    ALTER TABLE products
    ADD CONSTRAINT products_default_variant_id_fkey
    FOREIGN KEY (default_variant_id)
    REFERENCES variants(id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED
    """)

    create table(:product_images, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :product_id,
          references(:products,
            column: :id,
            type: :uuid,
            name: "product_images_product_id_fkey",
            on_delete: :delete_all
          ),
          null: false

      add :url, :text, null: false
      add :alt, :text
      add :position, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:product_images, [:product_id], name: "product_images_product_id_index")

    create unique_index(:product_images, [:product_id, :position],
             name: "product_images_unique_product_position_index"
           )
  end

  def down do
    drop_if_exists unique_index(:product_images, [:product_id, :position],
                     name: "product_images_unique_product_position_index"
                   )

    drop_if_exists index(:product_images, [:product_id], name: "product_images_product_id_index")

    drop table(:product_images)

    drop constraint(:products, "products_default_variant_id_fkey")

    drop constraint(:variants, "variants_compare_at_price_minor_non_negative")
    drop constraint(:variants, "variants_price_minor_non_negative")
    drop constraint(:variants, "variants_status_value_check")

    drop_if_exists unique_index(:variants, [:product_id],
                     where: "is_default = true",
                     name: "variants_unique_default_per_product_index"
                   )

    drop_if_exists index(:variants, [:product_id], name: "variants_product_id_index")
    drop_if_exists unique_index(:variants, [:sku], name: "variants_unique_sku_index")
    drop table(:variants)

    drop constraint(:products, "products_published_requires_published_at")
    drop constraint(:products, "products_status_value_check")

    drop_if_exists index(:products, [:published_at], name: "products_published_at_index")
    drop_if_exists index(:products, [:status], name: "products_status_index")
    drop_if_exists index(:products, [:category_id], name: "products_category_id_index")
    drop_if_exists unique_index(:products, [:slug], name: "products_unique_slug_index")
    drop table(:products)

    drop_if_exists unique_index(:catalog_categories, [:slug],
                     name: "catalog_categories_unique_slug_index"
                   )

    drop table(:catalog_categories)
  end
end
