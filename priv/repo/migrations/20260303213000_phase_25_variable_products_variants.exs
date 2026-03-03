defmodule Store.Repo.Migrations.Phase25VariableProductsVariants do
  @moduledoc """
  Adds per-product options/values/selections and variant signature/image support.
  """

  use Ecto.Migration

  def up do
    alter table(:variants) do
      add(
        :image_id,
        references(:product_images,
          column: :id,
          type: :uuid,
          name: "variants_image_id_fkey",
          on_delete: :nilify_all
        )
      )

      add(:selection_signature, :binary)
    end

    create(index(:variants, [:image_id], name: "variants_image_id_index"))

    create(
      unique_index(:variants, [:id, :product_id], name: "variants_unique_id_product_id_index")
    )

    create(
      unique_index(:variants, [:product_id, :selection_signature],
        where: "status = 'active' AND selection_signature IS NOT NULL",
        name: "variants_unique_active_selection_signature_index"
      )
    )

    create table(:product_options, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :product_id,
        references(:products,
          column: :id,
          type: :uuid,
          name: "product_options_product_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      add(:position, :bigint, null: false, default: 0)
      add(:selection_required, :boolean, null: false, default: true)

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
      unique_index(:product_options, [:product_id, :slug],
        name: "product_options_unique_product_slug_index"
      )
    )

    create(
      index(:product_options, [:product_id, :position, :id],
        name: "product_options_product_position_index"
      )
    )

    create(
      unique_index(:product_options, [:id, :product_id],
        name: "product_options_unique_id_product_id_index"
      )
    )

    create(
      constraint(
        :product_options,
        "product_options_slug_format_check",
        check: "slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'"
      )
    )

    create table(:product_option_values, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :product_option_id,
        references(:product_options,
          column: :id,
          type: :uuid,
          name: "product_option_values_product_option_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(:name, :text, null: false)
      add(:slug, :text, null: false)
      add(:position, :bigint, null: false, default: 0)

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
      unique_index(:product_option_values, [:product_option_id, :slug],
        name: "product_option_values_unique_option_slug_index"
      )
    )

    create(
      index(:product_option_values, [:product_option_id, :position, :id],
        name: "product_option_values_option_position_index"
      )
    )

    create(
      unique_index(:product_option_values, [:id, :product_option_id],
        name: "product_option_values_unique_id_option_id_index"
      )
    )

    create(
      constraint(
        :product_option_values,
        "product_option_values_slug_format_check",
        check: "slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'"
      )
    )

    create table(:variant_option_selections, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(
        :product_id,
        references(:products,
          column: :id,
          type: :uuid,
          name: "variant_option_selections_product_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :variant_id,
        references(:variants,
          column: :id,
          type: :uuid,
          name: "variant_option_selections_variant_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :product_option_id,
        references(:product_options,
          column: :id,
          type: :uuid,
          name: "variant_option_selections_product_option_id_fkey",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :product_option_value_id,
        references(:product_option_values,
          column: :id,
          type: :uuid,
          name: "variant_option_selections_product_option_value_id_fkey",
          on_delete: :delete_all
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
      unique_index(:variant_option_selections, [:variant_id, :product_option_id],
        name: "variant_option_selections_unique_variant_option_index"
      )
    )

    create(
      index(:variant_option_selections, [:product_option_value_id],
        name: "variant_option_selections_value_id_index"
      )
    )

    create(
      index(:variant_option_selections, [:product_id, :variant_id],
        name: "variant_option_selections_product_variant_index"
      )
    )

    create(
      index(:variant_option_selections, [:product_id, :product_option_id],
        name: "variant_option_selections_product_option_index"
      )
    )

    execute("""
    ALTER TABLE variant_option_selections
    ADD CONSTRAINT variant_option_selections_variant_product_fkey
    FOREIGN KEY (variant_id, product_id)
    REFERENCES variants(id, product_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY IMMEDIATE
    """)

    execute("""
    ALTER TABLE variant_option_selections
    ADD CONSTRAINT variant_option_selections_option_product_fkey
    FOREIGN KEY (product_option_id, product_id)
    REFERENCES product_options(id, product_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY IMMEDIATE
    """)

    execute("""
    ALTER TABLE variant_option_selections
    ADD CONSTRAINT variant_option_selections_value_option_fkey
    FOREIGN KEY (product_option_value_id, product_option_id)
    REFERENCES product_option_values(id, product_option_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY IMMEDIATE
    """)
  end

  def down do
    execute("""
    ALTER TABLE variant_option_selections
    DROP CONSTRAINT IF EXISTS variant_option_selections_value_option_fkey
    """)

    execute("""
    ALTER TABLE variant_option_selections
    DROP CONSTRAINT IF EXISTS variant_option_selections_option_product_fkey
    """)

    execute("""
    ALTER TABLE variant_option_selections
    DROP CONSTRAINT IF EXISTS variant_option_selections_variant_product_fkey
    """)

    drop_if_exists(
      index(:variant_option_selections, [:product_id, :product_option_id],
        name: "variant_option_selections_product_option_index"
      )
    )

    drop_if_exists(
      index(:variant_option_selections, [:product_id, :variant_id],
        name: "variant_option_selections_product_variant_index"
      )
    )

    drop_if_exists(
      index(:variant_option_selections, [:product_option_value_id],
        name: "variant_option_selections_value_id_index"
      )
    )

    drop_if_exists(
      unique_index(:variant_option_selections, [:variant_id, :product_option_id],
        name: "variant_option_selections_unique_variant_option_index"
      )
    )

    drop(table(:variant_option_selections))

    drop(constraint(:product_option_values, "product_option_values_slug_format_check"))

    drop_if_exists(
      unique_index(:product_option_values, [:id, :product_option_id],
        name: "product_option_values_unique_id_option_id_index"
      )
    )

    drop_if_exists(
      index(:product_option_values, [:product_option_id, :position, :id],
        name: "product_option_values_option_position_index"
      )
    )

    drop_if_exists(
      unique_index(:product_option_values, [:product_option_id, :slug],
        name: "product_option_values_unique_option_slug_index"
      )
    )

    drop(table(:product_option_values))

    drop(constraint(:product_options, "product_options_slug_format_check"))

    drop_if_exists(
      unique_index(:product_options, [:id, :product_id],
        name: "product_options_unique_id_product_id_index"
      )
    )

    drop_if_exists(
      index(:product_options, [:product_id, :position, :id],
        name: "product_options_product_position_index"
      )
    )

    drop_if_exists(
      unique_index(:product_options, [:product_id, :slug],
        name: "product_options_unique_product_slug_index"
      )
    )

    drop(table(:product_options))

    drop_if_exists(
      unique_index(:variants, [:product_id, :selection_signature],
        where: "status = 'active' AND selection_signature IS NOT NULL",
        name: "variants_unique_active_selection_signature_index"
      )
    )

    drop_if_exists(
      unique_index(:variants, [:id, :product_id], name: "variants_unique_id_product_id_index")
    )

    drop_if_exists(index(:variants, [:image_id], name: "variants_image_id_index"))

    alter table(:variants) do
      remove(:selection_signature)
      remove(:image_id)
    end
  end
end
