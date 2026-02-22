defmodule Store.Support.ID.UUIDv7 do
  @moduledoc """
  UUIDv7 helpers with explicit raw16 encode/decode helpers.
  """

  @type raw16 :: <<_::128>>

  @spec generate() :: String.t()
  def generate do
    Ash.UUIDv7.generate()
  end

  @spec bingenerate() :: raw16
  def bingenerate do
    Ash.UUIDv7.bingenerate()
  end

  @spec decode!(String.t() | raw16) :: raw16
  def decode!(<<_::128>> = raw16), do: raw16

  def decode!(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, raw16} ->
        raw16

      :error ->
        raise ArgumentError, "invalid UUID: #{inspect(uuid)}"
    end
  end

  def decode!(value) do
    raise ArgumentError, "invalid UUID input: #{inspect(value)}"
  end

  @spec encode!(raw16) :: String.t()
  def encode!(<<_::128>> = raw16) do
    case Ecto.UUID.load(raw16) do
      {:ok, uuid} ->
        uuid

      :error ->
        raise ArgumentError, "invalid raw16 UUID binary"
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(value) do
    _ = decode!(value)
    true
  rescue
    ArgumentError -> false
  end
end
