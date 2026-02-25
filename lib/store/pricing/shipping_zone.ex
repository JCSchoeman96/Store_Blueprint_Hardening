defmodule Store.Pricing.ShippingZone do
  @moduledoc """
  Persisted shipping destination zone used for deterministic shipping eligibility.
  """

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

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :shipping_rates, Store.Pricing.ShippingRate do
      destination_attribute(:shipping_zone_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_code, [:code])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create do
      accept([:code, :country_code, :region_code, :active])
      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)
      accept([:code, :country_code, :region_code, :active])
      change(&normalize_fields/2)
    end
  end

  postgres do
    table("shipping_zones")
    repo(Store.Repo)

    custom_indexes do
      index([:active], name: "shipping_zones_active_index")
      index([:country_code, :region_code], name: "shipping_zones_country_region_index")
    end
  end

  policies do
    policy action(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:update) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:code, &String.upcase/1)
    |> normalize_attr(:country_code, &String.upcase/1)
    |> normalize_attr(:region_code, &String.upcase/1)
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> transform.()

        Ash.Changeset.change_attribute(changeset, attr, empty_to_nil(normalized))

      _other ->
        changeset
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
