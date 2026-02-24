defmodule StoreWeb.ErrorJSONTest do
  use StoreWeb.ConnCase, async: true

  alias Store.Support.Errors.Error
  alias StoreWeb.ErrorJSON

  defmodule UnknownStruct do
    defstruct [:data]
  end

  test "renders 404" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ErrorJSON.render("500.json", %{}) == %{errors: %{detail: "Internal Server Error"}}
  end

  test "renders normalized error envelope for error.json" do
    error = Error.new("UNAUTHORIZED", "not signed in")

    assert %{
             errors: %{
               code: "UNAUTHORIZED",
               message: "not signed in",
               meta: %{}
             }
           } = ErrorJSON.render("error.json", %{error: error})
  end

  test "renders Ash.Error.Forbidden normalization" do
    error = %Ash.Error.Forbidden{}

    assert %{
             errors: %{
               code: "FORBIDDEN",
               message: "Forbidden",
               meta: %{reason: "forbidden"}
             }
           } = ErrorJSON.render("error.json", %{error: error})
  end

  test "renders Ash.Error.Invalid normalization" do
    error = %Ash.Error.Invalid{}

    assert %{
             errors: %{
               code: "VALIDATION_ERROR",
               message: "Validation failed",
               meta: %{}
             }
           } = ErrorJSON.render("error.json", %{error: error})
  end

  test "renders Ash.Error.Query.NotFound normalization" do
    error = %Ash.Error.Query.NotFound{}

    assert %{
             errors: %{
               code: "NOT_FOUND",
               message: "Resource not found",
               meta: %{}
             }
           } = ErrorJSON.render("error.json", %{error: error})
  end

  test "never raises: handles unknown codes, arbitrary terms, and unknown structs" do
    # Unknown code map
    unknown_map = %{code: "MYSTERY", message: "mystery"}

    assert %{errors: %{code: "INTERNAL_ERROR"}} =
             ErrorJSON.render("error.json", %{error: unknown_map})

    # Arbitrary term
    assert %{errors: %{code: "INTERNAL_ERROR"}} =
             ErrorJSON.render("error.json", %{error: :atoms_are_fine})

    # Unknown struct
    assert %{errors: %{code: "INTERNAL_ERROR"}} =
             ErrorJSON.render("error.json", %{error: %UnknownStruct{data: 1}})
  end
end
