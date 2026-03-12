defmodule StoreWeb.Plugs.WaitingRoom do
  @moduledoc """
  Endpoint-level waiting room for hot public routes.
  """

  import Plug.Conn

  alias StoreWeb.WaitingRoom

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = WaitingRoom.assign_live_scope(conn)

    case WaitingRoom.http_decision(conn) do
      {:allow, _metadata} ->
        conn

      {:deny, metadata} ->
        body = WaitingRoom.waiting_room_html(metadata.scope, metadata.refresh_seconds)

        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store, max-age=0")
        |> put_resp_header("retry-after", Integer.to_string(metadata.refresh_seconds))
        |> send_resp(:service_unavailable, body)
        |> halt()
    end
  end
end
