defmodule StoreWeb.HealthController do
  @moduledoc false

  use StoreWeb, :controller

  alias Store.Operations.Health

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{data: Health.live_status()})
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    status = Health.ready_status()
    http_status = if status.status == "ok", do: :ok, else: :service_unavailable

    conn
    |> put_status(http_status)
    |> json(%{data: status})
  end
end
