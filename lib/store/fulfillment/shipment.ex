defmodule Store.Fulfillment.Shipment do
  @moduledoc """
  Shipment lifecycle records for fulfillment orders.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false,
    domain: Store.Fulfillment

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.Authorization
  alias Store.Fulfillment.FulfillmentOrder
  alias Store.Orders.Order

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Fulfillment.Types.ShipmentState do
      allow_nil?(false)
      default(:created)
      public?(true)
    end

    attribute :carrier, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tracking_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :fulfillment_order, Store.Fulfillment.FulfillmentOrder do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  state_machine do
    initial_states([:created])
    default_initial_state(:created)

    transitions do
      transition(:mark_in_transit, from: :created, to: :in_transit)
      transition(:mark_delivered, from: :in_transit, to: :delivered)
      transition(:cancel, from: [:created, :in_transit], to: :canceled)
    end
  end

  actions do
    defaults([])

    read :read do
      primary?(true)

      prepare(fn query, context ->
        actor = Map.get(context, :actor)
        actor_id = actor && Map.get(actor, :id)
        source_context = Map.get(context, :source_context, %{})
        system_context? = get_in(source_context, [:system?]) == true
        authorization_disabled? = Map.get(context, :authorize?) == false

        cond do
          system_context? or authorization_disabled? ->
            query

          Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) ->
            query

          is_binary(actor_id) ->
            visible_fulfillment_order_ids = visible_fulfillment_order_ids(actor_id)
            Ash.Query.filter(query, expr(fulfillment_order_id in ^visible_fulfillment_order_ids))

          true ->
            Ash.Query.filter(query, expr(false))
        end
      end)
    end

    read :for_fulfillment_order do
      argument :fulfillment_order_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(fulfillment_order_id == ^arg(:fulfillment_order_id)))
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :create do
      accept([:fulfillment_order_id, :state, :carrier, :tracking_ref])
      change(&normalize_fields/2)
    end

    update :mark_in_transit do
      require_atomic?(false)
      accept([:carrier, :tracking_ref])
      change(&normalize_fields/2)
      change({Store.Support.Governance.TransitionState, target: :in_transit})
    end

    update :mark_delivered do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :delivered})
    end

    update :cancel do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :canceled})
    end
  end

  postgres do
    table("shipments")
    repo(Store.Repo)

    custom_indexes do
      index([:fulfillment_order_id], name: "shipments_fulfillment_order_id_index")
      index([:state, :inserted_at], name: "shipments_state_inserted_at_index")
      index([:tracking_ref], name: "shipments_unique_tracking_ref_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if(actor_present())
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:mark_in_transit) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:mark_delivered) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:cancel) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end
  end

  defp normalize_fields(changeset, _context) do
    changeset
    |> normalize_attr(:carrier)
    |> normalize_attr(:tracking_ref)
  end

  defp normalize_attr(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      value when is_binary(value) ->
        value = value |> String.trim() |> empty_to_nil()
        Ash.Changeset.change_attribute(changeset, field, value)

      _ ->
        changeset
    end
  end

  defp visible_fulfillment_order_ids(actor_id) do
    order_ids =
      Order
      |> Ash.Query.filter(expr(user_id == ^actor_id))
      |> Ash.read!(domain: Store.Orders, authorize?: false)
      |> Enum.map(& &1.id)

    case order_ids do
      [] ->
        []

      _ ->
        FulfillmentOrder
        |> Ash.Query.filter(expr(order_id in ^order_ids))
        |> Ash.read!(domain: Store.Fulfillment, authorize?: false)
        |> Enum.map(& &1.id)
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
