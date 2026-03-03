defmodule Store.Digital.DigitalAsset do
  @moduledoc """
  Digital file metadata and storage locator information.
  """

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
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 100)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :create do
      accept([
        :key,
        :title,
        :content_type,
        :byte_size,
        :storage_provider,
        :storage_bucket,
        :storage_object_key,
        :checksum_sha256,
        :status
      ])
    end

    update :update do
      require_atomic?(false)

      accept([
        :key,
        :title,
        :content_type,
        :byte_size,
        :storage_provider,
        :storage_bucket,
        :storage_object_key,
        :checksum_sha256,
        :status
      ])
    end

    update :archive do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :archived))
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :title, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :content_type, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :byte_size, :integer do
      allow_nil?(false)
      constraints(min: 0)
      default(0)
      public?(true)
    end

    attribute :storage_provider, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      default("s3")
      public?(true)
    end

    attribute :storage_bucket, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :storage_object_key, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :checksum_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, Store.Digital.Types.DigitalAssetStatus do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :product_digital_links, Store.Digital.ProductDigitalLink do
      destination_attribute(:digital_asset_id)
      public?(true)
    end

    has_many :download_grants, Store.Digital.DownloadGrant do
      destination_attribute(:digital_asset_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_key, [:key])
  end

  postgres do
    table("digital_assets")
    repo(Store.Repo)

    custom_indexes do
      index([:status, :inserted_at], name: "digital_assets_status_inserted_at_index")
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

    policy action(:archive) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
