defmodule StoreWeb.Plugs.WaitingRoomTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Store.Support.RateLimit.EtsBackend
  alias StoreWeb.LiveSocket
  alias StoreWeb.Plugs.WaitingRoom

  @session_opts Plug.Session.init(store: :cookie, key: "_waiting_room", signing_salt: "salt")

  setup do
    previous = Application.get_env(:store, :rate_limit, [])

    Application.put_env(
      :store,
      :rate_limit,
      Keyword.merge(previous,
        backend: EtsBackend,
        public_waiting_room_limit: 1,
        public_waiting_room_hard_limit: 2,
        public_waiting_room_window_seconds: 60,
        live_waiting_room_limit: 1,
        live_waiting_room_hard_limit: 2,
        live_waiting_room_window_seconds: 60,
        waiting_room_refresh_seconds: 10
      )
    )

    case :ets.whereis(:store_rate_limit) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    on_exit(fn ->
      Application.put_env(:store, :rate_limit, previous)

      case :ets.whereis(:store_rate_limit) do
        :undefined -> :ok
        table -> :ets.delete(table)
      end
    end)

    :ok
  end

  test "endpoint waiting room serves static html before router work" do
    assert conn(:get, "/shop")
           |> with_session()
           |> WaitingRoom.call([])
           |> Map.get(:status) != 503

    denied =
      conn(:get, "/shop")
      |> with_session()
      |> WaitingRoom.call([])

    assert denied.halted
    assert denied.status == 503
    assert get_resp_header(denied, "retry-after") == ["10"]
    assert denied.resp_body =~ "<meta http-equiv=\"refresh\" content=\"10\">"
    assert denied.resp_body =~ "Please wait"
  end

  test "live socket rejects throttled reconnects before liveview mount" do
    connect_info = %{session: %{"live_waiting_room_scope" => "checkout"}}
    socket = %Phoenix.Socket{}

    assert {:ok, _socket} = LiveSocket.connect(%{}, socket, connect_info)
    assert :error = LiveSocket.connect(%{}, socket, connect_info)
  end

  defp with_session(conn) do
    conn
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(@session_opts)
    |> fetch_session()
  end
end
