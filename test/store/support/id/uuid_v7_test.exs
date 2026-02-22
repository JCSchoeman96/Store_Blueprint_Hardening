defmodule Store.Support.ID.UUIDv7Test do
  use ExUnit.Case, async: true

  alias Store.Support.ID.UUIDv7

  test "generate/0 returns UUIDv7 string" do
    uuid = UUIDv7.generate()
    assert UUIDv7.valid?(uuid)
    assert String.at(uuid, 14) == "7"
  end

  test "bingenerate/0 returns raw16" do
    assert <<_::128>> = UUIDv7.bingenerate()
  end

  test "decode!/encode! roundtrip" do
    uuid = UUIDv7.generate()
    raw16 = UUIDv7.decode!(uuid)

    assert <<_::128>> = raw16
    assert UUIDv7.encode!(raw16) == uuid
  end

  test "valid?/1 rejects invalid UUID values" do
    refute UUIDv7.valid?("not-a-uuid")
    refute UUIDv7.valid?(123)
  end
end
