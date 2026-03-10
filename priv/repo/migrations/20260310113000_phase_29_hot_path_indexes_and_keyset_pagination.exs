defmodule Store.Repo.Migrations.Phase29HotPathIndexesAndKeysetPagination do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:products, [:status, :published_at],
                           name: "products_status_published_at_index"
                         )

    create_if_not_exists index(:orders, [:user_id, :inserted_at, :id],
                           name: "orders_user_id_inserted_at_id_index"
                         )

    create_if_not_exists index(:orders, [:state, :inserted_at, :id],
                           name: "orders_state_inserted_at_id_index"
                         )
  end
end
