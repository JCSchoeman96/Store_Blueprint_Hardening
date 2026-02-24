defmodule Store.Repo.Migrations.Phase09ImmutableSnapshots do
  @moduledoc """
  Adds immutable snapshot evidence tables for order line items and adjustments.
  """

  use Ecto.Migration

  def up do
    create table(:order_line_items, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id, references(:orders, type: :uuid, on_delete: :nothing), null: false

      add :line_no, :bigint, null: false
      add :currency, :text, null: false
      add :quantity, :bigint, null: false
      add :unit_price_minor, :bigint, null: false
      add :line_total_minor, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:order_line_items, [:order_id], name: "order_line_items_order_id_index")

    create unique_index(:order_line_items, [:order_id, :line_no],
             name: "order_line_items_unique_line_no_per_order_index"
           )

    create table(:order_adjustments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :order_id, references(:orders, type: :uuid, on_delete: :nothing), null: false

      add :sequence_no, :bigint, null: false
      add :currency, :text, null: false
      add :kind, :text, null: false
      add :amount_minor, :bigint, null: false
      add :reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:order_adjustments, [:order_id], name: "order_adjustments_order_id_index")

    create unique_index(:order_adjustments, [:order_id, :sequence_no],
             name: "order_adjustments_unique_sequence_no_per_order_index"
           )
  end

  def down do
    drop_if_exists unique_index(:order_adjustments, [:order_id, :sequence_no],
                     name: "order_adjustments_unique_sequence_no_per_order_index"
                   )

    drop_if_exists index(:order_adjustments, [:order_id],
                     name: "order_adjustments_order_id_index"
                   )

    drop table(:order_adjustments)

    drop_if_exists unique_index(:order_line_items, [:order_id, :line_no],
                     name: "order_line_items_unique_line_no_per_order_index"
                   )

    drop_if_exists index(:order_line_items, [:order_id], name: "order_line_items_order_id_index")

    drop table(:order_line_items)
  end
end
