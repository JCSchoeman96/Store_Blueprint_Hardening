defmodule StoreWeb.Plugs.EnsureCartToken do
  @moduledoc """
  Ensures a stable signed cart token cookie and mirrors it into session/assigns.
  """

  import Plug.Conn

  alias Store.Support.ID.UUIDv7

  @behaviour Plug

  @cookie_name "cart_token"
  @max_age 60 * 60 * 24 * 30

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie_name])

    token =
      conn.cookies[@cookie_name] ||
        conn.req_cookies[@cookie_name] ||
        UUIDv7.generate()

    conn
    |> maybe_put_cookie(token)
    |> put_session(:cart_token, token)
    |> assign(:cart_token, token)
  end

  defp maybe_put_cookie(%Plug.Conn{} = conn, token) do
    if conn.cookies[@cookie_name] do
      conn
    else
      put_resp_cookie(conn, @cookie_name, token,
        http_only: true,
        same_site: "Lax",
        max_age: @max_age,
        sign: true,
        secure: secure_cookie?(conn)
      )
    end
  end

  defp secure_cookie?(conn) do
    conn.scheme == :https or endpoint_scheme() == "https"
  end

  defp endpoint_scheme do
    :store
    |> Application.get_env(StoreWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:scheme)
  end
end
