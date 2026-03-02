defmodule Store.Catalog.Category do
  @moduledoc """
  Product categorization for storefront filtering and admin organization.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  attributes do
    uuid_v7_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      constraints(min_length: 1, match: ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :position, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :is_active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :products, Store.Catalog.Product do
      destination_attribute(:category_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_public do
      prepare(fn query, _context ->
        query
        |> Ash.Query.filter(expr(is_active == true))
        |> Ash.Query.sort(position: :asc, name: :asc, id: :asc)
      end)
    end

    read :read_for_admin do
      prepare(fn query, _context ->
        Ash.Query.sort(query, position: :asc, name: :asc, id: :asc)
      end)
    end

    create :create do
      accept([:slug, :name, :position, :is_active])
      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)
      accept([:slug, :name, :position, :is_active])
      change(&normalize_fields/2)
    end

    destroy(:destroy)
  end

  postgres do
    table("catalog_categories")
    repo(Store.Repo)
  end

  policies do
    policy action(:read_for_public) do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_slug()
    |> normalize_name()
  end

  defp normalize_slug(changeset) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.downcase()

        Ash.Changeset.change_attribute(changeset, :slug, normalized)

      _ ->
        changeset
    end
  end

  defp normalize_name(changeset) do
    case Ash.Changeset.get_attribute(changeset, :name) do
      value when is_binary(value) ->
        Ash.Changeset.change_attribute(changeset, :name, String.trim(value))

      _ ->
        changeset
    end
  end
end
