defmodule Store.Catalog.AvailabilityCacheTest do
  use ExUnit.Case, async: false

  alias Store.Catalog.AvailabilityCache

  @table :store_catalog_availability_cache

  setup do
    assert is_reference(:ets.whereis(@table))

    :ok
  end

  test "concurrent initialization does not crash on named table races" do
    results =
      1..20
      |> Task.async_stream(
        fn index ->
          product_id =
            "019cd83f#{String.pad_leading(Integer.to_string(index), 24, "0")}"

          assert :ok = AvailabilityCache.put(product_id, %{index: index}, 30)
          assert {:ok, %{index: ^index}} = AvailabilityCache.get(product_id)
        end,
        max_concurrency: 20,
        timeout: 5_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert is_reference(:ets.whereis(@table))
  end
end
