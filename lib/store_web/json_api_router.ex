defmodule StoreWeb.JsonApiRouter do
  @moduledoc false

  @open_api_file if(Mix.env() == :prod, do: "priv/static/open_api.json", else: nil)

  use AshJsonApi.Router,
    domains: [Store.Orders, Store.Payments],
    open_api: "/open_api",
    json_schema: "/json_schema",
    open_api_file: @open_api_file
end
