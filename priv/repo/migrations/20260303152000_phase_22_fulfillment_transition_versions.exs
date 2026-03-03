defmodule Store.Repo.Migrations.Phase22FulfillmentTransitionVersions do
  @moduledoc """
  Adds integer optimistic lock versions for fulfillment state transitions.
  """

  use Ecto.Migration

  def up do
    alter table(:fulfillment_orders) do
      add :version, :bigint, null: false, default: 1
    end

    alter table(:shipments) do
      add :version, :bigint, null: false, default: 1
    end
  end

  def down do
    alter table(:shipments) do
      remove :version
    end

    alter table(:fulfillment_orders) do
      remove :version
    end
  end
end
