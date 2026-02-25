defmodule Store.Repo.Migrations.Phase14InterlockUpsertIndexFix do
  @moduledoc """
  Rebuilds checkout/payment key uniqueness indexes so ON CONFLICT upserts target full unique indexes.
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:orders, [:checkout_key],
                     where: "checkout_key IS NOT NULL",
                     name: "orders_unique_checkout_key_index"
                   )

    create_if_not_exists unique_index(:orders, [:checkout_key],
                           name: "orders_unique_checkout_key_index"
                         )

    drop_if_exists unique_index(:payment_intents, [:payment_intent_key],
                     where: "payment_intent_key IS NOT NULL",
                     name: "payment_intents_unique_payment_intent_key_index"
                   )

    create_if_not_exists unique_index(:payment_intents, [:payment_intent_key],
                           name: "payment_intents_unique_payment_intent_key_index"
                         )
  end

  def down do
    drop_if_exists unique_index(:payment_intents, [:payment_intent_key],
                     name: "payment_intents_unique_payment_intent_key_index"
                   )

    create_if_not_exists unique_index(:payment_intents, [:payment_intent_key],
                           where: "payment_intent_key IS NOT NULL",
                           name: "payment_intents_unique_payment_intent_key_index"
                         )

    drop_if_exists unique_index(:orders, [:checkout_key],
                     name: "orders_unique_checkout_key_index"
                   )

    create_if_not_exists unique_index(:orders, [:checkout_key],
                           where: "checkout_key IS NOT NULL",
                           name: "orders_unique_checkout_key_index"
                         )
  end
end
