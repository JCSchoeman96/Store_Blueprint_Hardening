defmodule StoreWeb.API.ErrorResponderTest do
  use StoreWeb.ConnCase, async: true

  alias Store.Support.Errors.Error
  alias StoreWeb.API.ErrorResponder

  test "maps checkout concurrency errors to conflict or unprocessable statuses", %{conn: conn} do
    stale_conn = ErrorResponder.render(conn, Error.new("STALE_RECORD", "stale"))
    assert stale_conn.status == 409

    duplicate_conn = ErrorResponder.render(conn, Error.new("CHECKOUT_DUPLICATE", "duplicate"))
    assert duplicate_conn.status == 409

    reservation_conn =
      ErrorResponder.render(conn, Error.new("RESERVATION_CONFLICT", "reservation conflict"))

    assert reservation_conn.status == 409

    out_of_stock_conn = ErrorResponder.render(conn, Error.new("OUT_OF_STOCK", "sold out"))
    assert out_of_stock_conn.status == 422
  end
end
