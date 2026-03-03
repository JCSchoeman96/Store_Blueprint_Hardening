defmodule Store.Digital.DownloadGrant do
  @moduledoc """
  Customer entitlement to download a specific digital asset from an order line.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Digital

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_user do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 100)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :issue do
      accept([
        :order_id,
        :order_line_item_id,
        :digital_asset_id,
        :actor_user_id,
        :status,
        :issued_at,
        :expires_at,
        :max_downloads,
        :download_count,
        :revoked_reason,
        :idempotency_key
      ])

      upsert?(true)
      upsert_identity(:unique_order_line_item_asset)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :revoke do
      require_atomic?(false)
      accept([:revoked_reason])
      change(set_attribute(:status, :revoked))
    end

    update :expire do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :expired))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :actor_user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Digital.Types.DownloadGrantStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    attribute :issued_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :max_downloads, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(true)
    end

    attribute :download_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :revoked_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :order_line_item, Store.Orders.OrderLineItem do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :digital_asset, Store.Digital.DigitalAsset do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_order_line_item_asset, [:order_line_item_id, :digital_asset_id])
  end

  postgres do
    table("download_grants")
    repo(Store.Repo)

    custom_indexes do
      index([:actor_user_id], name: "download_grants_actor_user_id_index")
      index([:order_id], name: "download_grants_order_id_index")
      index([:expires_at], name: "download_grants_expires_at_index")
      index([:digital_asset_id], name: "download_grants_digital_asset_id_index")
      index([:status, :inserted_at], name: "download_grants_status_inserted_at_index")
      index([:idempotency_key], name: "download_grants_idempotency_key_index")
    end
  end

  policies do
    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:read_for_user) do
      access_type(:filter)
      authorize_if(expr(actor_user_id == ^actor(:id)))
    end

    policy action(:issue) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:revoke) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:expire) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
