defmodule StoreWeb.PageController do
  @moduledoc false

  use StoreWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
