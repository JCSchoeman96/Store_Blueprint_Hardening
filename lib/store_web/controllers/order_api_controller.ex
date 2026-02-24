defmodule StoreWeb.OrderApiController do
  @moduledoc false

  use StoreWeb, :controller

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.Order
  alias Store.Support.Errors.Error
  alias StoreWeb.API.ErrorResponder

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case conn.assigns[:current_user] do
      nil ->
        ErrorResponder.render(conn, Error.new("UNAUTHORIZED", "Authentication required"))

      actor ->
        case fetch_order(id, actor) do
          {:ok, nil} ->
            ErrorResponder.render(conn, Error.new("NOT_FOUND", "Resource not found"))

          {:ok, order} ->
            json(conn, %{data: %{id: order.id}})

          {:error, error} ->
            ErrorResponder.render(conn, error)
        end
    end
  end

  defp fetch_order(id, actor) do
    query =
      Order
      |> Ash.Query.filter(expr(id == ^id))

    case Ash.read(query, domain: Store.Orders, actor: actor) do
      {:ok, [order | _]} -> {:ok, order}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end
end
