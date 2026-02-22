defmodule Store.Support.ID.OrderRefTest do
  use ExUnit.Case, async: true

  alias Store.Support.ID.OrderRef

  test "generate/1 defaults to 9 chars and valid check digit" do
    ref = OrderRef.generate()

    assert String.length(ref) == 9
    assert OrderRef.valid?(ref)
    assert {:ok, ^ref} = OrderRef.normalize(ref)
  end

  test "generate/1 supports allowed payload sizes" do
    assert String.length(OrderRef.generate(payload_length: 6)) == 7
    assert String.length(OrderRef.generate(payload_length: 5)) == 6
  end

  test "normalize/1 uppercases valid lowercase inputs" do
    ref = OrderRef.generate()
    lowercase = String.downcase(ref)

    assert {:ok, ^ref} = OrderRef.normalize(lowercase)
  end

  test "normalize/1 rejects invalid alphabet characters" do
    assert {:error, :invalid_character} = OrderRef.normalize("1234567I9")
  end

  test "valid?/1 rejects wrong check digit" do
    ref = OrderRef.generate()
    bad = String.slice(ref, 0, 8) <> "0"

    if bad == ref do
      refute OrderRef.valid?(String.slice(ref, 0, 8) <> "1")
    else
      refute OrderRef.valid?(bad)
    end
  end
end
