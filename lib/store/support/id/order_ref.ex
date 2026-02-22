defmodule Store.Support.ID.OrderRef do
  @moduledoc """
  Customer-facing order reference generator and validator.

  Default format is 9 chars total:
  8-char payload + 1-char check digit.
  """

  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @alphabet_by_char @alphabet |> String.graphemes() |> Map.new(fn char -> {char, true} end)
  @value_by_char @alphabet |> String.graphemes() |> Enum.with_index() |> Map.new()
  @char_by_value @alphabet
                 |> String.graphemes()
                 |> Enum.with_index()
                 |> Map.new(fn {char, index} -> {index, char} end)
  @allowed_payload_lengths [8, 6, 5]

  @spec generate(keyword()) :: String.t()
  def generate(opts \\ []) do
    payload_length = Keyword.get(opts, :payload_length, 8)

    if payload_length in @allowed_payload_lengths do
      payload = random_payload(payload_length)
      payload <> check_digit(payload)
    else
      raise ArgumentError,
            "payload_length must be one of #{inspect(@allowed_payload_lengths)}"
    end
  end

  @spec valid?(String.t()) :: boolean()
  def valid?(value) when is_binary(value) do
    case normalize(value) do
      {:ok, _normalized} -> true
      {:error, _reason} -> false
    end
  end

  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.upcase()

    with :ok <- validate_length(normalized),
         :ok <- validate_chars(normalized),
         true <- valid_check_digit?(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_check_digit}
      {:error, _reason} = error -> error
    end
  end

  defp random_payload(length) do
    :crypto.strong_rand_bytes(length)
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte ->
      Map.fetch!(@char_by_value, rem(byte, 32))
    end)
  end

  defp validate_length(value) do
    payload_length = String.length(value) - 1

    if payload_length in @allowed_payload_lengths do
      :ok
    else
      {:error, :invalid_length}
    end
  end

  defp validate_chars(value) do
    if value
       |> String.graphemes()
       |> Enum.all?(&Map.has_key?(@alphabet_by_char, &1)) do
      :ok
    else
      {:error, :invalid_character}
    end
  end

  defp valid_check_digit?(value) do
    payload_length = String.length(value) - 1
    payload = String.slice(value, 0, payload_length)
    check = String.slice(value, payload_length, 1)
    check == check_digit(payload)
  end

  defp check_digit(payload) do
    checksum =
      payload
      |> String.graphemes()
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {char, index}, acc ->
        acc + Map.fetch!(@value_by_char, char) * index
      end)

    Map.fetch!(@char_by_value, rem(checksum, 32))
  end
end
