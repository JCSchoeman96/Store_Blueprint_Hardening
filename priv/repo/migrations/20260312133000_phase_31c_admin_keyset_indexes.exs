defmodule Store.Repo.Migrations.Phase31cAdminKeysetIndexes do
  use Ecto.Migration

  def change do
    create index(:email_outboxes, [:state, :inserted_at, :id],
             name: :email_outboxes_state_inserted_at_id_index
           )

    create index(:email_outboxes, [:template_kind, :inserted_at, :id],
             name: :email_outboxes_template_kind_inserted_at_id_index
           )

    create index(:fulfillment_orders, [:state, :inserted_at, :id],
             name: :fulfillment_orders_state_inserted_at_id_index
           )
  end
end
