defmodule Store.Orders.Facade do
  @moduledoc """
  Consumer-scoped read surfaces for orders.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Fulfillment.Facade, as: FulfillmentFacade
  alias Store.Orders.Order
  alias Store.Orders.{OrderAdjustment, OrderLineItem}
  alias Store.Orders.Queries.{OrderIndexQuery, OrderShowQuery}
  alias Store.Support.Errors.Error
  alias Store.Support.Errors.Normalize

  @spec list_orders_for_user(map(), OrderIndexQuery.t()) :: {:ok, [Order.t()]} | {:error, term()}
  def list_orders_for_user(actor, %OrderIndexQuery{} = query) when is_map(actor) do
    ash_query =
      Order
      |> Ash.Query.for_read(:read_for_user, %{}, actor: actor)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Store.Orders, actor: actor) do
      {:ok, orders} -> {:ok, orders}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec list_orders_for_admin(map(), OrderIndexQuery.t()) :: {:ok, [Order.t()]} | {:error, term()}
  def list_orders_for_admin(actor, %OrderIndexQuery{} = query) when is_map(actor) do
    ash_query =
      Order
      |> Ash.Query.for_read(:read_for_admin, %{}, actor: actor)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Store.Orders, actor: actor) do
      {:ok, orders} -> {:ok, orders}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_order_for_user(map(), OrderShowQuery.t()) :: {:ok, Order.t() | nil} | {:error, term()}
  def get_order_for_user(actor, %OrderShowQuery{id: id}) when is_map(actor) do
    ash_query = Ash.Query.for_read(Order, :get_for_user, %{id: id}, actor: actor)

    case Ash.read_one(ash_query, domain: Store.Orders, actor: actor) do
      {:ok, order} -> {:ok, order}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_order_for_admin(map(), OrderShowQuery.t()) ::
          {:ok, Order.t() | nil} | {:error, term()}
  def get_order_for_admin(actor, %OrderShowQuery{id: id}) when is_map(actor) do
    ash_query = Ash.Query.for_read(Order, :get_for_admin, %{id: id}, actor: actor)

    case Ash.read_one(ash_query, domain: Store.Orders, actor: actor) do
      {:ok, order} -> {:ok, order}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_order_detail_for_user(map(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_order_detail_for_user(actor, order_ref) when is_map(actor) and is_binary(order_ref) do
    order_query =
      Ash.Query.for_read(Order, :get_for_user_by_ref, %{order_ref: order_ref}, actor: actor)

    with {:ok, order} <- Ash.read_one(order_query, domain: Store.Orders, actor: actor),
         {:ok, detail} <- enrich_order_detail(order, actor) do
      {:ok, detail}
    else
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  def get_order_detail_for_user(_actor, _order_ref),
    do: {:error, Error.new("VALIDATION_ERROR", "order_ref must be a string")}

  defp enrich_order_detail(nil, _actor), do: {:ok, nil}

  defp enrich_order_detail(%Order{} = order, actor) do
    line_items_query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order.id))
      |> Ash.Query.sort(line_no: :asc)

    adjustments_query =
      OrderAdjustment
      |> Ash.Query.filter(expr(order_id == ^order.id))
      |> Ash.Query.sort(sequence_no: :asc)

    with {:ok, line_items} <- Ash.read(line_items_query, domain: Store.Orders, actor: actor),
         {:ok, adjustments} <- Ash.read(adjustments_query, domain: Store.Orders, actor: actor),
         {:ok, fulfillment_order} <-
           FulfillmentFacade.get_fulfillment_by_order_id_for_system(order.id) do
      {:ok,
       %{
         order: order,
         line_items: line_items,
         adjustments: adjustments,
         fulfillment_order: fulfillment_order,
         shipments: (fulfillment_order && Map.get(fulfillment_order, :shipments, [])) || [],
         fulfillment_items: (fulfillment_order && Map.get(fulfillment_order, :items, [])) || []
       }}
    end
  end
end
