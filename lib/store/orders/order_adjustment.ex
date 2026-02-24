defmodule Store.Orders.OrderAdjustment do
  @moduledoc """
  Immutable order adjustment snapshot evidence.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false,
    domain: Store.Orders

  import Ash.Expr
  require Ash.Query

  alias Store.Admin.Authorization
  alias Store.Orders.Order

  attributes do
    uuid_v7_primary_key(:id)

    attribute :sequence_no, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :kind, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :amount_minor, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :reason, :string do
      allow_nil?(true)
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
  end

  identities do
    identity(:unique_sequence_no_per_order, [:order_id, :sequence_no])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)

      prepare(fn query, context ->
        actor = Map.get(context, :actor)
        actor_id = actor && Map.get(actor, :id)

        cond do
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

    create :create do
      accept([:order_id, :sequence_no, :currency, :kind, :amount_minor, :reason])
    end
  end

  postgres do
    table("order_adjustments")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id], name: "order_adjustments_order_id_index")
    end
  end

  policies do
    policy action(:read) do
      access_type(:runtime)
      authorize_if(actor_present())
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp visible_order_ids(actor_id) do
    Order
    |> Ash.Query.filter(expr(user_id == ^actor_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false)
    |> Enum.map(& &1.id)
  end
end
