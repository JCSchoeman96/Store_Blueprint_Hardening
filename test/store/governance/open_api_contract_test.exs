defmodule Store.Governance.OpenApiContractTest do
  use ExUnit.Case, async: true

  @open_api_file "priv/static/open_api.json"

  test "static OpenAPI spec exists and stays read-only for Phase 17 routes" do
    assert File.exists?(@open_api_file)

    assert {:ok, open_api_json} = File.read(@open_api_file)
    assert {:ok, spec} = Jason.decode(open_api_json)

    paths = Map.fetch!(spec, "paths")

    for path <- [
          "/api/v1/orders",
          "/api/v1/orders/{id}",
          "/api/v1/admin/orders",
          "/api/v1/admin/orders/{id}",
          "/api/v1/admin/payment-intents",
          "/api/v1/admin/payment-intents/{id}"
        ] do
      assert Map.has_key?(paths, path)
    end

    Enum.each(paths, fn {_path, operations} ->
      assert Enum.sort(Map.keys(operations)) == ["get"]
    end)
  end
end
