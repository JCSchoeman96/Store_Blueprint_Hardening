defmodule Store.Support.ID.LockOrder do
  @moduledoc """
  Deterministic multi-record lock ordering helpers.
  """

  alias Store.Support.ID.BinaryUuidSort

  @type raw16 :: <<_::128>>

  @spec order_raw16_ids([String.t() | raw16]) :: [raw16]
  def order_raw16_ids(ids) when is_list(ids) do
    BinaryUuidSort.sort_raw16(ids)
  end

  @spec dedup_and_order_raw16_ids([String.t() | raw16]) :: [raw16]
  def dedup_and_order_raw16_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&BinaryUuidSort.normalize_raw16!/1)
    |> MapSet.new()
    |> MapSet.to_list()
    |> Enum.sort()
  end
end
