defmodule StoreWeb.OrderApiController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Orders
  alias Store.Support.Errors.Error
  alias StoreWeb.API.ErrorResponder
  alias StoreWeb.Params.OrderApiParams

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case conn.assigns[:current_user] do
      nil ->
        ErrorResponder.render(conn, Error.new("UNAUTHORIZED", "Authentication required"))

      actor ->
        case fetch_order(params, actor) do
          {:ok, nil} ->
            ErrorResponder.render(conn, Error.new("NOT_FOUND", "Resource not found"))

          {:ok, order} ->
            json(conn, %{data: %{id: order.id}})

          {:error, error} ->
            ErrorResponder.render(conn, error)
        end
    end
  end

  defp fetch_order(params, actor) do
    with {:ok, query} <- OrderApiParams.show_query(params) do
      Orders.fetch_order_for_api(query, actor)
    end
  end
end
