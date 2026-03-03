defmodule Store.Shipping.ShippingRateRule do
  @moduledoc """
  Persisted shipping quote rule used for deterministic quote options.
  """

  import Ash.Expr
  require Ash.Query

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

    attribute :currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :shipping_cost_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      default(0)
      public?(true)
    end

    attribute :weight_min_grams, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :weight_max_grams, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :free_over_subtotal_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :allow_free_shipping_coupon, :boolean do
      allow_nil?(false)
      default(false)
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

  relationships do
    belongs_to :shipping_zone, Store.Shipping.ShippingZone do
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :shipping_method, Store.Shipping.ShippingMethod do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
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

      argument :shipping_zone_id, :uuid do
        allow_nil?(true)
      end

      argument :shipping_method_id, :uuid do
        allow_nil?(true)
      end

      prepare(fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit) || 20
        zone_id = Ash.Query.get_argument(query, :shipping_zone_id)
        method_id = Ash.Query.get_argument(query, :shipping_method_id)

        query =
          query
          |> maybe_filter_zone(zone_id)
          |> maybe_filter_method(method_id)

        query
        |> Ash.Query.sort(inserted_at: :desc, id: :asc)
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
      accept([
        :code,
        :currency,
        :shipping_zone_id,
        :shipping_method_id,
        :shipping_cost_minor,
        :weight_min_grams,
        :weight_max_grams,
        :free_over_subtotal_minor,
        :allow_free_shipping_coupon,
        :active,
        :starts_at,
        :ends_at,
        :precedence_rank
      ])

      change(&normalize_fields/2)
      validate(&validate_weight_bounds/2)
    end

    update :update do
      require_atomic?(false)

      accept([
        :code,
        :currency,
        :shipping_zone_id,
        :shipping_method_id,
        :shipping_cost_minor,
        :weight_min_grams,
        :weight_max_grams,
        :free_over_subtotal_minor,
        :allow_free_shipping_coupon,
        :active,
        :starts_at,
        :ends_at,
        :precedence_rank
      ])

      change(&normalize_fields/2)
      validate(&validate_weight_bounds/2)
    end
  end

  code_interface do
    define(:list_for_admin,
      action: :admin_index,
      args: [:limit, :shipping_zone_id, :shipping_method_id]
    )

    define(:get_for_admin, action: :admin_get, args: [:id])
    define(:create_for_admin, action: :create)
    define(:update_for_admin, action: :update)
  end

  postgres do
    table("shipping_rates")
    repo(Store.Repo)

    custom_indexes do
      index([:currency, :active], name: "shipping_rates_currency_active_index")
      index([:starts_at, :ends_at], name: "shipping_rates_window_index")
      index([:shipping_zone_id], name: "shipping_rates_shipping_zone_id_index")

      index([:shipping_zone_id, :shipping_method_id, :active],
        name: "shipping_rates_zone_method_active_index"
      )

      index([:shipping_zone_id, :active], name: "shipping_rates_zone_active_index")
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

  defp maybe_filter_zone(query, zone_id) when is_binary(zone_id),
    do: Ash.Query.filter(query, expr(shipping_zone_id == ^zone_id))

  defp maybe_filter_zone(query, _zone_id), do: query

  defp maybe_filter_method(query, method_id) when is_binary(method_id),
    do: Ash.Query.filter(query, expr(shipping_method_id == ^method_id))

  defp maybe_filter_method(query, _method_id), do: query

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:code)
    |> normalize_attr(:currency)
  end

  defp normalize_attr(changeset, attr) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.upcase()

        Ash.Changeset.change_attribute(changeset, attr, normalized)

      _other ->
        changeset
    end
  end

  defp validate_weight_bounds(changeset, _context) do
    min_grams = Ash.Changeset.get_attribute(changeset, :weight_min_grams)
    max_grams = Ash.Changeset.get_attribute(changeset, :weight_max_grams)

    if is_integer(min_grams) and is_integer(max_grams) and min_grams > max_grams do
      {:error,
       field: :weight_max_grams, message: "must be greater than or equal to weight_min_grams"}
    else
      :ok
    end
  end
end
