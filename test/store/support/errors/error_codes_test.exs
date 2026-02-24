defmodule Store.Support.Errors.ErrorCodesTest do
  use ExUnit.Case, async: true

  alias Store.Support.Errors.Error
  alias Store.Support.Errors.ErrorCodes

  @doc """
  Parse `docs/governance/error_codes.md` assuming a pinned format:

    - SECTION headings, text, etc.
    - Codes as list items starting with `- CODE` (SCREAMING_SNAKE_CASE).

  Only the first SCREAMING_SNAKE_CASE token on those lines is treated as a code.
  """
  @spec documented_codes() :: [String.t()]
  def documented_codes do
    "docs/governance/error_codes.md"
    |> Path.expand(File.cwd!())
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim_leading(line)

      case Regex.run(~r/^- ([A-Z0-9_]+)/, trimmed, capture: :all_but_first) do
        [code] ->
          [code | acc]

        _ ->
          acc
      end
    end)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "registry contains all documented codes and has no duplicates" do
    doc_codes = documented_codes()
    reg_codes = ErrorCodes.all()

    assert Enum.sort(doc_codes) == Enum.sort(reg_codes)

    assert length(reg_codes) == length(Enum.uniq(reg_codes))
  end

  test "Error.new/3 accepts only known codes" do
    known_code = List.first(ErrorCodes.all()) || "UNAUTHORIZED"

    assert %Error{code: ^known_code} = Error.new(known_code, "message")

    assert_raise ArgumentError, ~r/unknown error code/, fn ->
      Error.new("THIS_IS_NOT_A_REAL_CODE", "message")
    end
  end
end
