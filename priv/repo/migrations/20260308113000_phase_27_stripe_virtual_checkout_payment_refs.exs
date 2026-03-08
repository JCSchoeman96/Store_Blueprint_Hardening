defmodule Store.Repo.Migrations.Phase27StripeVirtualCheckoutPaymentRefs do
  use Ecto.Migration

  def up do
    alter table(:payment_intents) do
      add :provider_customer_ref, :text
      add :provider_payment_method_ref, :text
    end

    create_if_not_exists(
      index(:payment_intents, [:provider_customer_ref],
        name: "payment_intents_provider_customer_ref_index"
      )
    )

    create_if_not_exists(
      index(:payment_intents, [:provider_payment_method_ref],
        name: "payment_intents_provider_payment_method_ref_index"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:payment_intents, [:provider_payment_method_ref],
        name: "payment_intents_provider_payment_method_ref_index"
      )
    )

    drop_if_exists(
      index(:payment_intents, [:provider_customer_ref],
        name: "payment_intents_provider_customer_ref_index"
      )
    )

    alter table(:payment_intents) do
      remove :provider_payment_method_ref
      remove :provider_customer_ref
    end
  end
end
