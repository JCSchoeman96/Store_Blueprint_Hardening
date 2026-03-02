defmodule Store.Carts.CartItem do
  @moduledoc """
  Cart line item keyed by cart and variant.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Carts

  attributes do
    uuid_v7_primary_key(:id)

    attribute :qty, :integer do
      allow_nil?(false)
      constraints(min: 1, max: 99)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :cart, Store.Carts.Cart do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_cart_variant, [:cart_id, :variant_id])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:cart_id, :variant_id, :qty])
    end

    update :update do
      accept([:qty])
    end

    destroy(:destroy)
  end

  postgres do
    table("cart_items")
    repo(Store.Repo)

    custom_indexes do
      index([:cart_id], name: "cart_items_cart_id_index")
      index([:variant_id], name: "cart_items_variant_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(context_equals(:system?, true))
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
