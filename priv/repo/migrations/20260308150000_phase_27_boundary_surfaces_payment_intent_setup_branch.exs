defmodule Store.Repo.Migrations.Phase27BoundarySurfacesPaymentIntentSetupBranch do
  use Ecto.Migration

  def change do
    alter table(:payment_intents) do
      add :purpose, :text, null: false, default: "order_checkout"
      add :subscription_id, references(:subscriptions, type: :uuid, on_delete: :nilify_all)
    end

    create index(:payment_intents, [:purpose], name: "payment_intents_purpose_index")

    create index(:payment_intents, [:subscription_id],
             name: "payment_intents_subscription_id_index"
           )
  end
end
