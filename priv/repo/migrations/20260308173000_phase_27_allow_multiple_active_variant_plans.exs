defmodule Store.Repo.Migrations.Phase27AllowMultipleActiveVariantPlans do
  use Ecto.Migration

  def change do
    drop_if_exists(
      unique_index(:variant_subscription_plans, [:variant_id],
        where: "active = true",
        name: "variant_subscription_plans_unique_active_variant_index"
      )
    )
  end
end
