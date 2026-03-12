defmodule Store.Fulfillment.FulfillmentOrder do
  @moduledoc """
  Physical fulfillment order lifecycle derived from immutable order snapshots.
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
  alias Store.Orders.Order

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Fulfillment.Types.FulfillmentOrderState do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :shipping_method_code, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :shipping_address_snapshot, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :notes, :string do
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
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end

    has_many :shipments, Store.Fulfillment.Shipment do
      destination_attribute(:fulfillment_order_id)
      public?(true)
    end

    has_many :items, Store.Fulfillment.FulfillmentItem do
      destination_attribute(:fulfillment_order_id)
      public?(true)
    end
  end

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:mark_packed, from: :pending, to: :packed)
      transition(:mark_shipped, from: :packed, to: :shipped)
      transition(:mark_delivered, from: :shipped, to: :delivered)
      transition(:cancel, from: [:pending, :packed, :shipped], to: :canceled)
    end
  end

  identities do
    identity(:unique_order_id, [:order_id])
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
            visible_order_ids = visible_order_ids(actor_id)
            Ash.Query.filter(query, expr(order_id in ^visible_order_ids))

          true ->
            Ash.Query.filter(query, expr(false))
        end
      end)
    end

    read :admin_queue do
      argument :state, Store.Fulfillment.Types.FulfillmentOrderState do
        allow_nil?(true)
      end

      pagination(keyset?: true, required?: false, default_limit: 20, max_page_size: 100)

      prepare(fn query, _context ->
        state = Ash.Query.get_argument(query, :state)

        case state do
          nil -> query
          state_value -> Ash.Query.filter(query, expr(state == ^state_value))
        end
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      end)
    end

    read :admin_get do
      argument :id, :uuid do
        allow_nil?(false)
      end

      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :get_for_order_id do
      argument :order_id, :uuid do
        allow_nil?(false)
      end

      get?(true)
      filter(expr(order_id == ^arg(:order_id)))
    end

    create :ensure_for_order do
      accept([:order_id, :shipping_method_code, :shipping_address_snapshot, :notes, :state])

      upsert?(true)
      upsert_identity(:unique_order_id)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_packed do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :packed})
    end

    update :mark_shipped do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :shipped})
    end

    update :mark_delivered do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :delivered})
    end

    update :cancel do
      require_atomic?(false)
      accept([:notes])
      change({Store.Support.Governance.TransitionState, target: :canceled})
    end
  end

  postgres do
    table("fulfillment_orders")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id], name: "fulfillment_orders_unique_order_id_index")
      index([:state, :inserted_at], name: "fulfillment_orders_state_inserted_at_index")
      index([:state, :inserted_at, :id], name: "fulfillment_orders_state_inserted_at_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if(actor_present())
    end

    policy action(:ensure_for_order) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:mark_packed) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:mark_shipped) do
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

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end
  end

  defp visible_order_ids(actor_id) do
    Order
    |> Ash.Query.filter(expr(user_id == ^actor_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false)
    |> Enum.map(& &1.id)
  end
end
