defmodule Store.Digital.ProductDigitalLink do
  @moduledoc """
  Link table between sellable catalog items and digital assets.
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
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [position: :asc, id: :asc]))
    end

    create :create do
      accept([
        :product_id,
        :variant_id,
        :digital_asset_id,
        :position,
        :grant_expires_in_days,
        :grant_max_downloads
      ])

      validate(&validate_one_target/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :position,
        :grant_expires_in_days,
        :grant_max_downloads
      ])
    end

    destroy(:destroy)
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute :position, :integer do
      allow_nil?(false)
      constraints(min: 0)
      default(0)
      public?(true)
    end

    attribute :grant_expires_in_days, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(true)
    end

    attribute :grant_max_downloads, :integer do
      allow_nil?(true)
      constraints(min: 1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :product, Store.Catalog.Product do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :digital_asset, Store.Digital.DigitalAsset do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  postgres do
    table("product_digital_links")
    repo(Store.Repo)

    custom_indexes do
      index([:digital_asset_id], name: "product_digital_links_digital_asset_id_index")
      index([:product_id], name: "product_digital_links_product_id_index")
      index([:variant_id], name: "product_digital_links_variant_id_index")
      index([:product_id, :position, :id], name: "product_digital_links_product_position_index")
      index([:variant_id, :position, :id], name: "product_digital_links_variant_position_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
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

  defp validate_one_target(changeset, _context) do
    product_id = Ash.Changeset.get_attribute(changeset, :product_id)
    variant_id = Ash.Changeset.get_attribute(changeset, :variant_id)

    cond do
      is_binary(product_id) and is_nil(variant_id) ->
        :ok

      is_nil(product_id) and is_binary(variant_id) ->
        :ok

      true ->
        {:error,
         field: :product_id, message: "exactly one of product_id or variant_id must be set"}
    end
  end
end
