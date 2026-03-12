defmodule Store.Repo.Migrations.Phase32ToolLeadSubmissions do
  @moduledoc false

  use Ecto.Migration

  def change do
    create table(:tool_lead_submissions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :tool_slug, :text, null: false
      add :name, :text, null: false
      add :email, :text, null: false
      add :phone, :text
      add :consent_contact, :boolean, null: false, default: false
      add :consent_store_data, :boolean, null: false, default: false
      add :score, :integer, null: false
      add :category, :text, null: false
      add :answers, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_lead_submissions, [:tool_slug])
    create index(:tool_lead_submissions, [:email])
    create index(:tool_lead_submissions, [:inserted_at])
  end
end
