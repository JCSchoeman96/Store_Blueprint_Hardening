defmodule Store.Catalog.ProductImage do
  @moduledoc """
  Product image metadata for storefront rendering.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  attributes do
    uuid_v7_primary_key(:id)

    attribute :url, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :alt, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :position, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :product, Store.Catalog.Product do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_product_position, [:product_id, :position])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create do
      accept([:product_id, :url, :alt, :position])
      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)
      accept([:url, :alt, :position])
      change(&normalize_fields/2)
    end

    destroy(:destroy)
  end

  postgres do
    table("product_images")
    repo(Store.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:url)
    |> normalize_attr(:alt)
  end

  defp normalize_attr(changeset, attr) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        value = String.trim(value)
        Ash.Changeset.change_attribute(changeset, attr, empty_to_nil(value))

      _ ->
        changeset
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
