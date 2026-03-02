defmodule Store.Catalog.Variant do
  @moduledoc """
  Sellable variant identity used for inventory and checkout normalization.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  attributes do
    uuid_v7_primary_key(:id)

    attribute :is_default, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :sku, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :title, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :currency_code, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :price_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :compare_at_price_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :status, Store.Catalog.Types.VariantStatus do
      allow_nil?(false)
      default(:active)
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
    identity(:unique_sku, [:sku])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_public do
      filter(expr(status == :active))
    end

    read(:read_for_admin)

    create :create do
      accept([
        :product_id,
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :status
      ])

      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
    end

    create :create_for_product do
      accept([
        :product_id,
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :status
      ])

      argument(:forced_id, :uuid, allow_nil?: false, public?: false)

      change(&force_id_from_argument/2)
      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :is_default,
        :sku,
        :title,
        :currency_code,
        :price_minor,
        :compare_at_price_minor,
        :status
      ])

      change(&normalize_fields/2)
      validate(&validate_compare_at/2)
    end

    update :archive do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :archived))
    end
  end

  postgres do
    table("variants")
    repo(Store.Repo)

    custom_indexes do
      index([:product_id], name: "variants_product_id_index")
      index([:is_default], name: "variants_is_default_index")
    end
  end

  policies do
    policy action(:read_for_public) do
      authorize_if(always())
    end

    policy action([:read, :read_for_admin]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:archive) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:sku, &String.upcase/1)
    |> normalize_attr(:currency_code, &String.upcase/1)
    |> normalize_title()
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

  defp normalize_title(changeset) do
    case Ash.Changeset.get_attribute(changeset, :title) do
      value when is_binary(value) ->
        value = String.trim(value)
        Ash.Changeset.change_attribute(changeset, :title, empty_to_nil(value))

      _ ->
        changeset
    end
  end

  defp validate_compare_at(changeset, _context) do
    price_minor = Ash.Changeset.get_attribute(changeset, :price_minor)
    compare_minor = Ash.Changeset.get_attribute(changeset, :compare_at_price_minor)

    if is_integer(compare_minor) and is_integer(price_minor) and compare_minor < price_minor do
      {:error, field: :compare_at_price_minor, message: "must be greater than or equal to price"}
    else
      :ok
    end
  end

  defp force_id_from_argument(changeset, _context) do
    case Ash.Changeset.get_argument(changeset, :forced_id) do
      nil -> changeset
      id -> Ash.Changeset.force_change_attribute(changeset, :id, id)
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
