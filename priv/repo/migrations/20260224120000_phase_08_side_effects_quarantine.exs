defmodule Store.Repo.Migrations.Phase08SideEffectsQuarantine do
  @moduledoc false

  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    alter table(:webhook_receipts) do
      add :raw_body, :text, null: false, default: ""
      add :headers, :map, null: false, default: fragment("'{}'::jsonb")
    end
  end

  def down do
    alter table(:webhook_receipts) do
      remove :headers
      remove :raw_body
    end

    Oban.Migrations.down()
  end
end
