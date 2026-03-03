defmodule Store.Catalog.ProductOption do
  @moduledoc """
  Per-product option axis used for deterministic variant selection.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  attributes do
    uuid_v7_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :slug, :string do
      allow_nil?(false)
      constraints(min_length: 1, match: ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
      public?(true)
    end

    attribute :position, :integer do
      allow_nil?(false)
      constraints(min: 0)
      default(0)
      public?(true)
    end

    attribute :selection_required, :boolean do
      allow_nil?(false)
      default(true)
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

    has_many :values, Store.Catalog.ProductOptionValue do
      destination_attribute(:product_option_id)
      public?(true)
    end

    has_many :variant_option_selections, Store.Catalog.VariantOptionSelection do
      destination_attribute(:product_option_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_product_slug, [:product_id, :slug])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_product do
      argument(:product_id, :uuid, allow_nil?: false)
      filter(expr(product_id == ^arg(:product_id)))
      prepare(build(sort: [position: :asc, id: :asc]))
    end

    create :create do
      accept([:product_id, :name, :slug, :position, :selection_required])
      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)
      accept([:name, :slug, :position, :selection_required])
      change(&normalize_fields/2)
    end

    destroy(:destroy)
  end

  postgres do
    table("product_options")
    repo(Store.Repo)

    custom_indexes do
      index([:product_id, :position, :id], name: "product_options_product_position_index")
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type([:create, :update, :destroy]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:name, & &1)
    |> normalize_attr(:slug, &String.downcase/1)
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized = value |> String.trim() |> transform.()
        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _ ->
        changeset
    end
  end
end
