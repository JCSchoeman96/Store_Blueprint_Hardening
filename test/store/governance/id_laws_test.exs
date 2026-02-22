defmodule Store.Governance.IDLawsTest do
  use ExUnit.Case, async: true

  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.ID.LockOrder
  alias Store.Support.ID.PrefixedId
  alias Store.Support.ID.UUIDv7

  test "binary UUID sort and lock order use the same canonical raw16 ordering" do
    ids = [
      "018ecb40-c457-73e6-a400-000398daddd9",
      "018ecb40-c457-73e6-a400-000398daddd7",
      "018ecb40-c457-73e6-a400-000398daddd8"
    ]

    assert BinaryUuidSort.sort_raw16(ids) == LockOrder.order_raw16_ids(ids)
  end

  test "prefixed IDs are boundary-safe and enforce lowercase UUID encoding" do
    uuid = UUIDv7.generate() |> String.upcase()

    assert {:ok, encoded} = PrefixedId.encode("ord", uuid)
    assert encoded =~ ~r/^ord_[0-9a-f-]+$/
    assert {:ok, %{prefix: "ord", uuid: parsed_uuid}} = PrefixedId.parse(encoded)
    assert parsed_uuid == String.slice(encoded, 4, String.length(encoded) - 4)
  end

  test "phase docs retain explicit BAN language on UUID string sorting" do
    text = File.read!("STORE_BLUEPRINT.md")

    assert String.contains?(text, "BAN:")
    assert String.contains?(String.downcase(text), "uuid")
    assert String.contains?(String.downcase(text), "string")
    assert String.contains?(String.downcase(text), "sort")
  end
end
