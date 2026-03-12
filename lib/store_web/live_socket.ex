defmodule StoreWeb.LiveSocket do
  @moduledoc """
  LiveView socket with edge admission control for reconnect storms.
  """

  use Phoenix.LiveView.Socket

  alias Phoenix.LiveView.Socket, as: LiveViewSocket
  alias StoreWeb.WaitingRoom

  @impl true
  def connect(_params, socket, connect_info) do
    case WaitingRoom.socket_decision(connect_info) do
      {:allow, _metadata} -> {:ok, socket}
      {:deny, _metadata} -> :error
    end
  end

  @impl true
  def id(socket), do: LiveViewSocket.id(socket)
end
