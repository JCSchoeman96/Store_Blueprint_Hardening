defmodule Store.Support.SentryEventFilterTest do
  use ExUnit.Case, async: true

  alias Phoenix.Router.NoRouteError
  alias Store.Support.SentryEventFilter

  test "filters noisy phoenix router misses" do
    exception =
      NoRouteError.exception(conn: Plug.Test.conn("GET", "/wp-admin"), router: StoreWeb.Router)

    assert SentryEventFilter.exclude_exception?(exception, :plug)
  end

  test "filters ecto no results errors" do
    assert SentryEventFilter.exclude_exception?(%Ecto.NoResultsError{}, :plug)
  end

  test "allows other exceptions through" do
    refute SentryEventFilter.exclude_exception?(%RuntimeError{message: "boom"}, :plug)
  end
end
