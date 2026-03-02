defmodule Store.Checkout.CheckoutDraft do
  @moduledoc """
  Durable checkout draft keyed by cart id and cart version.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Checkout

  attributes do
    uuid_v7_primary_key(:id)

    attribute :checkout_key, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :cart_version, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, Store.Checkout.Types.CheckoutDraftStatus do
      allow_nil?(false)
      default(:open)
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
  end

  identities do
    identity(:unique_checkout_key, [:checkout_key])
    identity(:unique_cart_id_cart_version, [:cart_id, :cart_version])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:checkout_key, :cart_id, :cart_version, :user_id, :status])
    end

    read :get_by_checkout_key do
      get?(true)

      argument :checkout_key, :string do
        allow_nil?(false)
      end

      filter(expr(checkout_key == ^arg(:checkout_key)))
    end
  end

  postgres do
    table("checkout_drafts")
    repo(Store.Repo)

    custom_indexes do
      index([:cart_id], name: "checkout_drafts_cart_id_index")
      index([:user_id], name: "checkout_drafts_user_id_index")
      index([:status], name: "checkout_drafts_status_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(expr(user_id == ^actor(:id)))
      authorize_if(context_equals(:system?, true))
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
