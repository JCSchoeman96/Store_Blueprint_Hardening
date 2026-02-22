defmodule Store.Support.ID.BinaryUuidSort do
  @moduledoc """
  Canonical UUID sorting by unsigned lexicographic raw16 byte order.

  This module implements the constitutional BAN on UUID string sorting
  for ordering, hashing/signing canonicalization, and lock acquisition.
  """

  alias Store.Support.ID.UUIDv7

  @type raw16 :: UUIDv7.raw16()

  @spec normalize_raw16!(String.t() | raw16) :: raw16
  def normalize_raw16!(value), do: UUIDv7.decode!(value)

  @spec sort_raw16([String.t() | raw16]) :: [raw16]
  def sort_raw16(values) when is_list(values) do
    values
    |> Enum.map(&normalize_raw16!/1)
    |> Enum.sort()
  end

  @spec sort_uuids([String.t() | raw16]) :: [String.t()]
  def sort_uuids(values) when is_list(values) do
    values
    |> sort_raw16()
    |> Enum.map(&UUIDv7.encode!/1)
  end

  @spec compare_raw16(String.t() | raw16, String.t() | raw16) :: :lt | :eq | :gt
  def compare_raw16(left, right) do
    left_raw16 = normalize_raw16!(left)
    right_raw16 = normalize_raw16!(right)

    cond do
      left_raw16 < right_raw16 -> :lt
      left_raw16 > right_raw16 -> :gt
      true -> :eq
    end
  end
end
