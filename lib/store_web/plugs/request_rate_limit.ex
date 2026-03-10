defmodule StoreWeb.Plugs.RequestRateLimit do
  @moduledoc """
  Applies coarse runtime-configured rate limits for operational surfaces.
  """

  import Plug.Conn

  alias Store.Support.Errors.Error
  alias Store.Support.RateLimit
  alias StoreWeb.API.ErrorResponder

  def init(opts), do: opts

  def call(conn, opts) do
    scope = Keyword.fetch!(opts, :scope)
    config = Application.get_env(:store, :rate_limit, [])
    limit = Keyword.fetch!(config, :"#{scope}_limit")
    window_seconds = Keyword.fetch!(config, :"#{scope}_window_seconds")
    key = rate_limit_key(scope, conn)

    case RateLimit.allow?(scope, key, limit, window_seconds) do
      {:ok, :allow} ->
        conn

      {:ok, :deny} ->
        conn
        |> put_status(:too_many_requests)
        |> ErrorResponder.render(Error.new("RATE_LIMITED", "rate limit exceeded"))
        |> halt()

      {:error, _reason} ->
        conn
    end
  end

  defp rate_limit_key(scope, conn) do
    ip =
      conn.remote_ip
      |> Tuple.to_list()
      |> Enum.join(".")

    "#{scope}:#{ip}"
  end
end
