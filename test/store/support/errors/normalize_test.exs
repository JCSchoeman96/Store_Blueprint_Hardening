defmodule Store.Support.Errors.NormalizeTest do
  use ExUnit.Case, async: true

  alias Ash.Error.{Forbidden, Invalid}
  alias Store.Support.Errors.{Error, Normalize}

  test "passes through Store.Support.Errors.Error" do
    error = Error.new("UNAUTHORIZED", "not signed in")

    assert %Error{code: "UNAUTHORIZED", message: "not signed in"} =
             Normalize.normalize(error)

    assert %{
             code: "UNAUTHORIZED",
             message: "not signed in",
             meta: %{}
           } = Normalize.to_map(error)
  end

  test "rebuilds from map with code/message/meta" do
    map = %{"code" => "FORBIDDEN", "message" => "nope", "meta" => %{"k" => "v"}}

    assert %Error{code: "FORBIDDEN", message: "nope", meta: %{"k" => "v"}} =
             Normalize.normalize(map)
  end

  test "falls back to INTERNAL_ERROR without leaking internals" do
    normalized = Normalize.normalize(:some_unexpected_term)

    assert %Error{code: "INTERNAL_ERROR", message: "Internal error", meta: %{}} = normalized
  end

  test "does not raise on unknown code and maps to INTERNAL_ERROR" do
    map = %{"code" => "SOME_UNKNOWN_CODE", "message" => "msg", "meta" => %{}}

    assert %Error{code: "INTERNAL_ERROR", message: "Internal error", meta: %{}} =
             Normalize.normalize(map)
  end

  test "scrubs secret-like meta keys and truncates long strings" do
    long = String.duplicate("x", 300)

    map = %{
      "code" => "VALIDATION_ERROR",
      "message" => "m",
      "meta" => %{
        "token" => "abc",
        safe: long,
        password: "supersecret"
      }
    }

    %Error{meta: meta} = Normalize.normalize(map)

    assert byte_size(meta[:safe]) == 200
    refute Map.has_key?(meta, :password)
    refute Map.has_key?(meta, "token")
  end

  test "maps Ash forbidden and invalid errors to canonical codes" do
    forbidden = struct(Forbidden)
    invalid = struct(Invalid)

    assert %Error{code: "FORBIDDEN"} = Normalize.normalize(forbidden)
    assert %Error{code: "VALIDATION_ERROR"} = Normalize.normalize(invalid)
  end
end
