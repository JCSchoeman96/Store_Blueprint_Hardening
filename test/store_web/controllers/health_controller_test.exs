defmodule StoreWeb.HealthControllerTest do
  use StoreWeb.ConnCase, async: false

  test "live endpoint returns operational heartbeat", %{conn: conn} do
    conn = get(conn, "/health/live")

    assert %{"data" => %{"status" => "ok", "checks" => %{"application" => %{"status" => "ok"}}}} =
             json_response(conn, 200)
  end

  test "ready endpoint returns readiness contract", %{conn: conn} do
    conn = get(conn, "/health/ready")
    body = json_response(conn, 200)

    assert get_in(body, ["data", "status"]) == "ok"
    assert get_in(body, ["data", "checks", "repo", "status"]) == "ok"
    assert get_in(body, ["data", "checks", "direct_repo", "status"]) == "ok"
    assert get_in(body, ["data", "checks", "oban", "status"]) == "ok"
  end
end
