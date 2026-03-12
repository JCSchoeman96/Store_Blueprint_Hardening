defmodule Store.Repo.Migrations.Phase31PendingProviderSetup do
  use Ecto.Migration

  def change do
    alter table(:orders) do
      add :provider_setup_started_at, :utc_datetime_usec
    end

    create index(:orders, [:state, :provider_setup_started_at],
             name: "orders_state_provider_setup_started_at_index"
           )
  end
end
