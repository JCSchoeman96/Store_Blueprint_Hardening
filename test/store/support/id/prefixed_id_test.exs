defmodule Store.Support.ID.PrefixedIdTest do
  use ExUnit.Case, async: true

  alias Store.Support.ID.PrefixedId

  test "encode/2 emits <prefix>_<uuid-lowercase>" do
    uuid = "018ECB40-C457-73E6-A400-000398DADDD7"

    assert {:ok, value} = PrefixedId.encode("ord", uuid)
    assert value == "ord_018ecb40-c457-73e6-a400-000398daddd7"
  end

  test "parse/1 returns prefix and lowercase uuid when valid" do
    assert {:ok, %{prefix: "prd", uuid: "018ecb40-c457-73e6-a400-000398daddd8"}} =
             PrefixedId.parse("prd_018ecb40-c457-73e6-a400-000398daddd8")
  end

  test "parse/1 rejects uppercase UUIDs to enforce lowercase boundary format" do
    assert {:error, :invalid_uuid} =
             PrefixedId.parse("ord_018ECB40-C457-73E6-A400-000398DADDD7")
  end

  test "valid?/2 checks both formatting and expected prefix" do
    value = "pay_018ecb40-c457-73e6-a400-000398daddd9"

    assert PrefixedId.valid?(value, "pay")
    refute PrefixedId.valid?(value, "ord")
  end

  test "encode/2 rejects invalid prefixes" do
    assert {:error, :invalid_prefix} =
             PrefixedId.encode("ORD", "018ecb40-c457-73e6-a400-000398daddd9")
  end
end
