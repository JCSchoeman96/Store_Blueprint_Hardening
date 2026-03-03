defmodule Store.Shipping.ShippingMethod do
  @moduledoc """
  Persisted shipping method used for quote selection and fulfillment routing.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Shipping

  attributes do
    uuid_v7_primary_key(:id)

    attribute :code, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      constraints(min_length: 1)
      public?(true)
    end

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :sort_order, :integer do
      allow_nil?(false)
      default(100)
      public?(true)
    end

    attribute :requires_address, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :shipping_rate_rules, Store.Shipping.ShippingRateRule do
      destination_attribute(:shipping_method_id)
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

    read :admin_index do
      argument :limit, :integer do
        allow_nil?(false)
        default(20)
        constraints(min: 1, max: 100)
      end

      prepare(fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit) || 20

        query
        |> Ash.Query.sort(sort_order: :asc, inserted_at: :desc, id: :asc)
        |> Ash.Query.limit(limit)
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
      accept([:code, :name, :active, :sort_order, :requires_address])
      change(&normalize_fields/2)
    end

    update :update do
      require_atomic?(false)
      accept([:code, :name, :active, :sort_order, :requires_address])
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
    table("shipping_methods")
    repo(Store.Repo)

    custom_indexes do
      index([:active], name: "shipping_methods_active_index")
      index([:sort_order], name: "shipping_methods_sort_order_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
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
    |> normalize_attr(:code, &String.upcase/1)
    |> normalize_attr(:name, &String.trim/1)
  end

  defp normalize_attr(changeset, attr, transform) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> transform.()

        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _other ->
        changeset
    end
  end
end
