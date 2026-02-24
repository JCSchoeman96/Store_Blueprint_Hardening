defmodule StoreWeb.RawBodyReader do
  @moduledoc false

  alias Plug.Conn

  @spec read_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Conn.assign(conn, :raw_body, append_raw_body(conn, body))}

      {:more, body, conn} ->
        {:more, body, Conn.assign(conn, :raw_body, append_raw_body(conn, body))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_raw_body(conn, body) do
    (conn.assigns[:raw_body] || "") <> body
  end
end
