defmodule Store.Pricing.TaxRate do
  @moduledoc """
  Persisted tax rate definition used for deterministic line-level tax computation.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Pricing

  attributes do
    uuid_v7_primary_key(:id)

    attribute :code, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :country_code, :string do
      allow_nil?(false)
      constraints(min_length: 2, max_length: 2)
      public?(true)
    end

    attribute :region_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :product_tax_category, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :rate_basis_points, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :shipping_taxable, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :ends_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :precedence_rank, :integer do
      allow_nil?(false)
      default(100)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_code, [:code])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :admin_index do
      argument :limit, :integer do
        allow_nil?(false)
        default(20)
        constraints(min: 1, max: 100)
      end

      prepare(fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit) || 20
        query |> Ash.Query.sort(inserted_at: :desc, id: :asc) |> Ash.Query.limit(limit)
      end)
    end

    read :admin_get do
      argument :id, :uuid do
        allow_nil?(false)
      end

      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    create :create do
      accept([
        :code,
        :country_code,
        :region_code,
        :product_tax_category,
        :rate_basis_points,
        :shipping_taxable,
        :active,
        :starts_at,
        :ends_at,
        :precedence_rank
      ])

      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :code,
        :country_code,
        :region_code,
        :product_tax_category,
        :rate_basis_points,
        :shipping_taxable,
        :active,
        :starts_at,
        :ends_at,
        :precedence_rank
      ])

      change(&normalize_fields/2)
    end
  end

  code_interface do
    define(:list_for_admin, action: :admin_index, args: [:limit])
    define(:get_for_admin, action: :admin_get, args: [:id])
    define(:create_for_admin, action: :create)
    define(:update_for_admin, action: :update)
  end

  postgres do
    table("tax_rates")
    repo(Store.Repo)

    custom_indexes do
      index([:country_code, :region_code], name: "tax_rates_country_region_index")
      index([:product_tax_category], name: "tax_rates_product_tax_category_index")
      index([:active], name: "tax_rates_active_index")
      index([:starts_at, :ends_at], name: "tax_rates_window_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end

    policy action(:update) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:code)
    |> normalize_attr(:country_code)
    |> normalize_attr(:region_code)
    |> normalize_attr(:product_tax_category)
  end

  defp normalize_attr(changeset, attr) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.upcase()
          |> empty_to_nil()

        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _other ->
        changeset
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
