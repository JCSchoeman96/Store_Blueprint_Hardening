defmodule Store.Subscriptions.VariantSubscriptionPlan do
  @moduledoc """
  Variant-to-subscription-plan attachment.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :subscription_plan, Store.Subscriptions.SubscriptionPlan do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_variant_plan, [:variant_id, :subscription_plan_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_active_for_variant do
      argument :variant_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(variant_id == ^arg(:variant_id) and active == true))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :attach do
      accept([:variant_id, :subscription_plan_id, :active])
      upsert?(true)
      upsert_identity(:unique_variant_plan)
      upsert_fields([:active])
      return_skipped_upsert?(true)
    end

    update :set_active do
      require_atomic?(false)
      accept([:active])
    end
  end

  code_interface do
    define(:list_active_for_variant, action: :read_active_for_variant, args: [:variant_id])
    define(:list_for_admin, action: :read_for_admin)
  end

  postgres do
    table("variant_subscription_plans")
    repo(Store.Repo)

    custom_indexes do
      index([:variant_id], name: "variant_subscription_plans_variant_id_index")
      index([:subscription_plan_id], name: "variant_subscription_plans_plan_id_index")
      index([:active], name: "variant_subscription_plans_active_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
