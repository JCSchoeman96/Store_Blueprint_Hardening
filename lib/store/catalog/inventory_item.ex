defmodule Store.Catalog.InventoryItem do
  @moduledoc """
  Inventory counters per variant for strict no-oversell reservation flows.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  attributes do
    uuid_v7_primary_key(:id)

    attribute :variant_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :stock_on_hand, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :reserved_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :allow_oversell, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_variant_id, [:variant_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:variant_id, :stock_on_hand, :reserved_count, :allow_oversell])
    end

    update :update_counts do
      accept([:stock_on_hand, :reserved_count, :allow_oversell])
    end
  end

  postgres do
    table("inventory_items")
    repo(Store.Repo)

    custom_indexes do
      index([:allow_oversell], name: "inventory_items_allow_oversell_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:create, :update_counts]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
