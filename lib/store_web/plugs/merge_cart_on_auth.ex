defmodule StoreWeb.Plugs.MergeCartOnAuth do
  @moduledoc """
  Shared authenticated merge hook for guest cart token into user cart.
  """

  import Plug.Conn

  require Logger

  alias Store.Carts.Facade, as: CartsFacade

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    user = conn.assigns[:current_user]
    token = get_session(conn, :cart_token)

    if is_map(user) and is_binary(token) do
      case CartsFacade.merge_token_into_user_for_user(user, token) do
        {:ok, _result} ->
          conn

        {:error, error} ->
          Logger.debug("cart merge hook failed: #{inspect(error)}")
          conn
      end
    else
      conn
    end
  end
end
