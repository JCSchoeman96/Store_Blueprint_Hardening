defmodule Store.Support.ID.PrefixedId do
  @moduledoc """
  Prefixed ID helpers for boundary-safe identifiers.

  Enforced format: `<prefix>_<uuid-lowercase>`.
  """

  alias Store.Support.ID.UUIDv7

  @prefix_regex ~r/^[a-z][a-z0-9_]*$/
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @spec encode(String.t(), String.t() | <<_::128>>) :: {:ok, String.t()} | {:error, atom()}
  def encode(prefix, uuid) when is_binary(prefix) do
    with :ok <- validate_prefix(prefix),
         raw16 <- UUIDv7.decode!(uuid) do
      {:ok, "#{prefix}_#{UUIDv7.encode!(raw16)}"}
    else
      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_uuid}
    end
  rescue
    ArgumentError -> {:error, :invalid_uuid}
  end

  @spec encode!(String.t(), String.t() | <<_::128>>) :: String.t()
  def encode!(prefix, uuid) do
    case encode(prefix, uuid) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid prefixed id input: #{inspect(reason)}"
    end
  end

  @spec parse(String.t()) :: {:ok, %{prefix: String.t(), uuid: String.t()}} | {:error, atom()}
  def parse(value) when is_binary(value) do
    case String.split(value, "_", parts: 2) do
      [prefix, uuid] ->
        with :ok <- validate_prefix(prefix),
             :ok <- validate_uuid_string(uuid) do
          {:ok, %{prefix: prefix, uuid: uuid}}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(value, expected_prefix) when is_binary(value) and is_binary(expected_prefix) do
    case parse(value) do
      {:ok, %{prefix: prefix}} -> prefix == expected_prefix
      {:error, _reason} -> false
    end
  end

  defp validate_prefix(prefix) do
    if Regex.match?(@prefix_regex, prefix) do
      :ok
    else
      {:error, :invalid_prefix}
    end
  end

  defp validate_uuid_string(uuid) do
    if Regex.match?(@uuid_regex, uuid) do
      :ok
    else
      {:error, :invalid_uuid}
    end
  end
end
