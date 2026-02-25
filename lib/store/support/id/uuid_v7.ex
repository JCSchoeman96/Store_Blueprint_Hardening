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

  @spec decode(String.t() | raw16) :: {:ok, raw16} | :error
  def decode(<<_::128>> = raw16), do: {:ok, raw16}

  def decode(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, raw16} -> {:ok, raw16}
      :error -> :error
    end
  end

  def decode(_value), do: :error

  @spec decode!(String.t() | raw16) :: raw16
  def decode!(value) do
    case decode(value) do
      {:ok, raw16} ->
        raw16

      :error when is_binary(value) ->
        raise ArgumentError, "invalid UUID: #{inspect(value)}"

      :error ->
        raise ArgumentError, "invalid UUID input: #{inspect(value)}"
    end
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
    match?({:ok, _}, decode(value))
  end
end
