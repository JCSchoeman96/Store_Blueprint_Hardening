defmodule StoreWeb.WaitingRoom do
  @moduledoc """
  Edge admission control helpers for public flash-sale routes and LiveView socket upgrades.
  """

  import Plug.Conn

  alias Plug.Conn
  alias Store.Support.RateLimit

  @session_scope_key "live_waiting_room_scope"
  @http_event [:store, :waiting_room, :http]
  @socket_event [:store, :waiting_room, :socket]
  @public_scopes [:shop, :cart, :checkout]

  @type scope :: :shop | :cart | :checkout
  @type decision_metadata :: %{
          scope: scope(),
          decision: :allow | :deny,
          mode: :normal | :soft | :hard,
          count: non_neg_integer(),
          conservative_limit: pos_integer(),
          hard_limit: pos_integer(),
          window_seconds: pos_integer(),
          refresh_seconds: pos_integer()
        }

  @spec session_scope_key() :: String.t()
  def session_scope_key, do: @session_scope_key

  @spec assign_live_scope(Conn.t()) :: Conn.t()
  def assign_live_scope(%Conn{method: method} = conn) when method in ["GET", "HEAD"] do
    if browser_scope_path?(conn.request_path) do
      scope =
        case public_scope_for_path(conn.request_path) do
          nil -> "none"
          value -> Atom.to_string(value)
        end

      conn
      |> fetch_session()
      |> put_session(@session_scope_key, scope)
    else
      conn
    end
  end

  def assign_live_scope(conn), do: conn

  @spec http_decision(Conn.t()) ::
          {:allow, nil | decision_metadata()} | {:deny, decision_metadata()}
  def http_decision(%Conn{method: method} = conn) when method in ["GET", "HEAD"] do
    case public_scope_for_path(conn.request_path) do
      nil -> {:allow, nil}
      scope -> decide(:http, scope)
    end
  end

  def http_decision(_conn), do: {:allow, nil}

  @spec socket_decision(map()) ::
          {:allow, nil | decision_metadata()} | {:deny, decision_metadata()}
  def socket_decision(connect_info) when is_map(connect_info) do
    case socket_scope(connect_info) do
      nil -> {:allow, nil}
      scope -> decide(:socket, scope)
    end
  end

  def socket_decision(_connect_info), do: {:allow, nil}

  @spec waiting_room_html(scope(), pos_integer()) :: String.t()
  def waiting_room_html(scope, refresh_seconds)
      when scope in @public_scopes and is_integer(refresh_seconds) and refresh_seconds > 0 do
    title = waiting_room_title(scope)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="#{refresh_seconds}">
        <title>Please wait</title>
        <style>
          :root { color-scheme: dark; }
          body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            background: #0f1414;
            color: #f5f4ea;
            font-family: Georgia, "Iowan Old Style", serif;
          }
          main {
            max-width: 34rem;
            padding: 2.5rem;
            border: 1px solid rgba(245, 244, 234, 0.16);
            background: linear-gradient(180deg, rgba(245, 244, 234, 0.06), rgba(245, 244, 234, 0.02));
            box-shadow: 0 22px 60px rgba(0, 0, 0, 0.25);
          }
          h1 { margin: 0 0 0.75rem; font-size: 2rem; }
          p { margin: 0 0 0.9rem; line-height: 1.5; color: rgba(245, 244, 234, 0.82); }
          strong { color: #f5f4ea; }
        </style>
      </head>
      <body>
        <main>
          <h1>Please wait</h1>
          <p><strong>#{title}</strong> is under heavy demand right now.</p>
          <p>Your browser will retry automatically in #{refresh_seconds} seconds. You do not need to refresh manually.</p>
          <p>This waiting room is protecting live inventory and checkout capacity so active buyers can finish cleanly.</p>
        </main>
      </body>
    </html>
    """
  end

  @spec public_scope_for_path(String.t()) :: scope() | nil
  def public_scope_for_path(path) when is_binary(path) do
    cond do
      path == "/shop" or String.starts_with?(path, "/shop/") -> :shop
      path == "/cart" -> :cart
      path == "/checkout" or String.starts_with?(path, "/checkout/") -> :checkout
      true -> nil
    end
  end

  def public_scope_for_path(_path), do: nil

  defp socket_scope(%{session: %{@session_scope_key => scope}}) when is_binary(scope) do
    case scope do
      "shop" -> :shop
      "cart" -> :cart
      "checkout" -> :checkout
      _ -> nil
    end
  end

  defp socket_scope(_connect_info), do: nil

  defp decide(channel, scope) do
    %{
      conservative_limit: conservative_limit,
      hard_limit: hard_limit,
      window_seconds: window_seconds
    } =
      limits_for(channel)

    refresh_seconds = waiting_room_refresh_seconds()

    if conservative_limit <= 0 or hard_limit <= 0 or window_seconds <= 0 do
      {:allow, nil}
    else
      key = "global:#{scope}"

      case RateLimit.check(rate_limit_scope(channel), key, hard_limit, window_seconds) do
        {:ok, %{count: count}} ->
          metadata =
            waiting_room_metadata(
              scope,
              count,
              conservative_limit,
              hard_limit,
              window_seconds,
              refresh_seconds
            )

          emit_telemetry(channel, metadata)
          waiting_room_result(metadata)

        {:error, _reason} ->
          {:allow, nil}
      end
    end
  end

  defp emit_telemetry(:http, metadata) do
    :telemetry.execute(@http_event, %{count: metadata.count}, Map.delete(metadata, :count))
  end

  defp emit_telemetry(:socket, metadata) do
    :telemetry.execute(@socket_event, %{count: metadata.count}, Map.delete(metadata, :count))
  end

  defp waiting_room_metadata(
         scope,
         count,
         conservative_limit,
         hard_limit,
         window_seconds,
         refresh_seconds
       ) do
    decision = if count > conservative_limit, do: :deny, else: :allow

    %{
      scope: scope,
      decision: decision,
      mode: throttle_mode(count, conservative_limit, hard_limit),
      count: count,
      conservative_limit: conservative_limit,
      hard_limit: hard_limit,
      window_seconds: window_seconds,
      refresh_seconds: refresh_seconds
    }
  end

  defp waiting_room_result(%{decision: :deny} = metadata), do: {:deny, metadata}
  defp waiting_room_result(metadata), do: {:allow, metadata}

  defp throttle_mode(count, _conservative_limit, hard_limit) when count > hard_limit, do: :hard

  defp throttle_mode(count, conservative_limit, _hard_limit) when count > conservative_limit,
    do: :soft

  defp throttle_mode(_count, _conservative_limit, _hard_limit), do: :normal

  defp limits_for(:http) do
    config = Application.get_env(:store, :rate_limit, [])
    conservative_limit = Keyword.get(config, :public_waiting_room_limit, 380)

    %{
      conservative_limit: conservative_limit,
      hard_limit:
        max(Keyword.get(config, :public_waiting_room_hard_limit, 450), conservative_limit),
      window_seconds: Keyword.get(config, :public_waiting_room_window_seconds, 10)
    }
  end

  defp limits_for(:socket) do
    config = Application.get_env(:store, :rate_limit, [])
    conservative_limit = Keyword.get(config, :live_waiting_room_limit, 380)

    %{
      conservative_limit: conservative_limit,
      hard_limit:
        max(Keyword.get(config, :live_waiting_room_hard_limit, 450), conservative_limit),
      window_seconds: Keyword.get(config, :live_waiting_room_window_seconds, 10)
    }
  end

  defp waiting_room_refresh_seconds do
    Application.get_env(:store, :rate_limit, [])
    |> Keyword.get(:waiting_room_refresh_seconds, 10)
  end

  defp rate_limit_scope(:http), do: :waiting_room_http
  defp rate_limit_scope(:socket), do: :waiting_room_socket

  defp waiting_room_title(:shop), do: "The storefront"
  defp waiting_room_title(:cart), do: "The cart"
  defp waiting_room_title(:checkout), do: "Checkout"

  defp browser_scope_path?(path) when is_binary(path) do
    not String.starts_with?(path, "/api") and
      not String.starts_with?(path, "/assets") and
      not String.starts_with?(path, "/images") and
      not String.starts_with?(path, "/fonts")
  end
end
