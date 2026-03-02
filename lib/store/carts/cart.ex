defmodule Store.Carts.Cart do
  @moduledoc """
  Persistent cart for guest/user storefront flows.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Carts

  attributes do
    uuid_v7_primary_key(:id)

    attribute :token, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, Store.Carts.Types.CartStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    attribute :merged_into_cart_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :items, Store.Carts.CartItem do
      destination_attribute(:cart_id)
      public?(true)
    end

    belongs_to :merged_into_cart, __MODULE__ do
      source_attribute(:merged_into_cart_id)
      destination_attribute(:id)
      attribute_writable?(true)
      allow_nil?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:token, :user_id, :status, :merged_into_cart_id, :version])
    end

    update :update do
      accept([:token, :user_id, :status, :merged_into_cart_id, :version])
    end
  end

  postgres do
    table("carts")
    repo(Store.Repo)

    custom_indexes do
      index([:user_id], name: "carts_user_id_index")
      index([:status], name: "carts_status_index")
      index([:merged_into_cart_id], name: "carts_merged_into_cart_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(expr(user_id == ^actor(:id) and status == :active))
      authorize_if(expr(token == ^context(:cart_token) and status == :active))
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
