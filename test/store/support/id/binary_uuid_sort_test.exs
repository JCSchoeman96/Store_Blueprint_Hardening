defmodule Store.Support.ID.BinaryUuidSortTest do
  use ExUnit.Case, async: true

  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.ID.UUIDv7

  test "sort_raw16/1 returns canonical raw16 ordering" do
    ids = [
      "018ecb40-c457-73e6-a400-000398daddd9",
      "018ecb40-c457-73e6-a400-000398daddd7",
      "018ecb40-c457-73e6-a400-000398daddd8"
    ]

    sorted = BinaryUuidSort.sort_raw16(ids)

    assert Enum.all?(sorted, &(byte_size(&1) == 16))
    assert Enum.map(sorted, &UUIDv7.encode!/1) == Enum.sort(ids)
  end

  test "sort_uuids/1 preserves canonical raw16 order in encoded output" do
    ids = [
      "018ecb40-c457-73e6-a400-000398daddd9",
      UUIDv7.decode!("018ecb40-c457-73e6-a400-000398daddd7"),
      "018ecb40-c457-73e6-a400-000398daddd8"
    ]

    assert BinaryUuidSort.sort_uuids(ids) == [
             "018ecb40-c457-73e6-a400-000398daddd7",
             "018ecb40-c457-73e6-a400-000398daddd8",
             "018ecb40-c457-73e6-a400-000398daddd9"
           ]
  end

  test "compare_raw16/2 returns deterministic ordering result" do
    left = "018ecb40-c457-73e6-a400-000398daddd7"
    right = "018ecb40-c457-73e6-a400-000398daddd9"

    assert BinaryUuidSort.compare_raw16(left, right) == :lt
    assert BinaryUuidSort.compare_raw16(right, left) == :gt
    assert BinaryUuidSort.compare_raw16(left, left) == :eq
  end

  test "normalize_raw16/1 returns tagged error for invalid values" do
    assert {:ok, <<_::128>>} = BinaryUuidSort.normalize_raw16(UUIDv7.generate())
    assert :error = BinaryUuidSort.normalize_raw16("not-a-uuid")
    assert :error = BinaryUuidSort.normalize_raw16(:invalid)
  end
end
