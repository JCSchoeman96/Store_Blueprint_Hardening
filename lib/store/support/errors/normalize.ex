defmodule Store.Support.Errors.Normalize do
  @moduledoc """
  Normalizes internal errors into the stable `%Store.Support.Errors.Error{}` envelope.

  This is the choke point for anything that crosses the web boundary.
  It MUST NEVER raise; unknown codes or types always downgrade to INTERNAL_ERROR.
  """

  alias Ash.Error.{Forbidden, Invalid}
  alias Ash.Error.Query.NotFound
  alias Store.Support.Errors.{Error, ErrorCodes}

  @type normalized :: Error.t()

  @max_meta_keys 25
  @max_string_length 200
  @max_list_length 20

  @secret_fragments [
    "password",
    "token",
    "secret",
    "authorization",
    "cookie",
    "session",
    "credit",
    "card",
    "iban",
    "bank"
  ]

  @spec normalize(term()) :: normalized()
  def normalize(%Error{} = error), do: error

  def normalize(%Forbidden{}) do
    safe_new("FORBIDDEN", "Forbidden", %{reason: "forbidden"})
  end

  def normalize(%Invalid{}) do
    safe_new("VALIDATION_ERROR", "Validation failed", %{})
  end

  def normalize(%NotFound{}) do
    safe_new("NOT_FOUND", "Resource not found", %{})
  end

  # Fallback for already-normalized maps (e.g. from APIs that call Error.to_map/1).
  def normalize(%{"code" => code, "message" => message} = map)
      when is_binary(code) and is_binary(message) do
    meta = Map.get(map, "meta", %{})
    safe_new(code, message, meta)
  end

  def normalize(%{code: code, message: message} = map)
      when is_binary(code) and is_binary(message) do
    meta = Map.get(map, :meta, %{})
    safe_new(code, message, meta)
  end

  # In later phases, add explicit clauses for Ash.Error.* variants and map them
  # to canonical codes (UNAUTHORIZED, FORBIDDEN, INVALID_STATE_TRANSITION, etc).

  # Generic fallback: treat anything else as an INTERNAL_ERROR without leaking internals.
  def normalize(_other) do
    safe_new("INTERNAL_ERROR", "Internal error", %{})
  end

  @spec to_map(term()) :: map()
  def to_map(error) do
    error
    |> normalize()
    |> Error.to_map()
  end

  defp safe_new(code, message, meta) when is_binary(code) and is_binary(message) do
    meta = scrub_meta(meta)

    if ErrorCodes.exists?(code) do
      %Error{code: code, message: message, meta: meta}
    else
      %Error{code: "INTERNAL_ERROR", message: "Internal error", meta: %{}}
    end
  end

  defp scrub_meta(meta) when is_map(meta) do
    meta
    |> Enum.reject(fn {key, _} -> secret_key?(key) end)
    |> Enum.take(@max_meta_keys)
    |> Enum.into(%{}, fn {key, value} ->
      {key, scrub_value(value)}
    end)
  end

  defp scrub_meta(_), do: %{}

  defp scrub_value(value) when is_binary(value) do
    if String.length(value) > @max_string_length do
      String.slice(value, 0, @max_string_length)
    else
      value
    end
  end

  defp scrub_value(value) when is_list(value) do
    value
    |> Enum.take(@max_list_length)
    |> Enum.map(&scrub_value/1)
  end

  defp scrub_value(%{} = value), do: scrub_meta(value)
  defp scrub_value(value), do: value

  defp secret_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(fn key_str ->
      Enum.any?(@secret_fragments, &String.contains?(key_str, &1))
    end)
  end
end
