defmodule Store.Orders.Facade do
  @moduledoc """
  Consumer-scoped read surfaces for orders.
  """

  alias Store.Orders.Order
  alias Store.Orders.Queries.{OrderIndexQuery, OrderShowQuery}
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
end
