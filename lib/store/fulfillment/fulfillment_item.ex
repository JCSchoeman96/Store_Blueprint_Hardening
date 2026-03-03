defmodule Store.Fulfillment.FulfillmentItem do
  @moduledoc """
  Immutable fulfillment item rows derived from order line snapshot evidence.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
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

    attribute :variant_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :product_title_snapshot, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :variant_title_snapshot, :string do
      allow_nil?(true)
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

    belongs_to :order_line_item, Store.Orders.OrderLineItem do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_order_line_per_fulfillment, [:fulfillment_order_id, :order_line_item_id])
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
      accept([
        :fulfillment_order_id,
        :order_line_item_id,
        :variant_id,
        :quantity,
        :product_title_snapshot,
        :variant_title_snapshot
      ])

      upsert?(true)
      upsert_identity(:unique_order_line_per_fulfillment)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  postgres do
    table("fulfillment_items")
    repo(Store.Repo)

    custom_indexes do
      index([:fulfillment_order_id, :order_line_item_id],
        name: "fulfillment_items_unique_order_line_item_index"
      )

      index([:variant_id], name: "fulfillment_items_variant_id_index")
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
end
