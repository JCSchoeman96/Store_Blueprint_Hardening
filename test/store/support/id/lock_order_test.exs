defmodule Store.Support.ID.LockOrderTest do
  use ExUnit.Case, async: true

  alias Store.Support.ID.LockOrder
  alias Store.Support.ID.UUIDv7

  test "order_raw16_ids/1 sorts ids in canonical lock order" do
    ids = [
      "018ecb40-c457-73e6-a400-000398daddd9",
      "018ecb40-c457-73e6-a400-000398daddd7",
      "018ecb40-c457-73e6-a400-000398daddd8"
    ]

    assert LockOrder.order_raw16_ids(ids)
           |> Enum.map(&UUIDv7.encode!/1) == [
             "018ecb40-c457-73e6-a400-000398daddd7",
             "018ecb40-c457-73e6-a400-000398daddd8",
             "018ecb40-c457-73e6-a400-000398daddd9"
           ]
  end

  test "dedup_and_order_raw16_ids/1 removes duplicates deterministically" do
    ids = [
      "018ecb40-c457-73e6-a400-000398daddd8",
      "018ecb40-c457-73e6-a400-000398daddd7",
      "018ecb40-c457-73e6-a400-000398daddd8"
    ]

    assert LockOrder.dedup_and_order_raw16_ids(ids)
           |> Enum.map(&UUIDv7.encode!/1) == [
             "018ecb40-c457-73e6-a400-000398daddd7",
             "018ecb40-c457-73e6-a400-000398daddd8"
           ]
  end
end
