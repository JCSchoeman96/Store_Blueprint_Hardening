defmodule StoreWeb.Plugs.RemoteIpTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias StoreWeb.Plugs.RemoteIp

  setup do
    previous = Application.get_env(:store, :trusted_proxy, [])

    Application.put_env(:store, :trusted_proxy,
      headers: ["cf-connecting-ip", "x-forwarded-for"],
      proxies: ["173.245.48.0/20"]
    )

    on_exit(fn ->
      Application.put_env(:store, :trusted_proxy, previous)
    end)

    :ok
  end

  test "rewrites remote_ip from trusted Cloudflare proxy headers" do
    conn =
      conn(:get, "/shop")
      |> Map.put(:remote_ip, {173, 245, 48, 12})
      |> put_req_header("cf-connecting-ip", "198.51.100.24")
      |> RemoteIp.call([])

    assert conn.remote_ip == {198, 51, 100, 24}
  end

  test "ignores forwarded headers from untrusted proxies" do
    conn =
      conn(:get, "/shop")
      |> Map.put(:remote_ip, {203, 0, 113, 8})
      |> put_req_header("cf-connecting-ip", "198.51.100.24")
      |> RemoteIp.call([])

    assert conn.remote_ip == {203, 0, 113, 8}
  end
end
