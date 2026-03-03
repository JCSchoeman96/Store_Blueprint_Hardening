defmodule Store.Shipping.QuoteHash do
  @moduledoc """
  Deterministic quote hash generation for shipping quote evidence.
  """

  alias Store.Shipping.Types.QuoteEvidence
  alias Store.Support.ID.BinaryUuidSort

  @spec hash_evidence(QuoteEvidence.t()) :: String.t()
  def hash_evidence(%QuoteEvidence{} = evidence) do
    payload = QuoteEvidence.hash_payload(evidence)
    canonical_json = payload |> canonical_term() |> Jason.encode!()

    :crypto.mac(:hmac, :sha256, quote_hash_secret(), canonical_json)
    |> Base.encode16(case: :lower)
  end

  defp quote_hash_secret do
    :store
    |> Application.get_env(:shipping, [])
    |> Keyword.fetch!(:quote_hash_secret)
  end

  defp canonical_term(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonical_term(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {normalize_term_key(key), canonical_term(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Map.new()
  end

  defp canonical_term(value) when is_list(value) do
    normalized = Enum.map(value, &canonical_term/1)

    if uuid_string_list?(normalized) do
      BinaryUuidSort.sort_uuids(normalized)
    else
      normalized
    end
  end

  defp canonical_term(value), do: value

  defp normalize_term_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_term_key(key) when is_binary(key), do: key
  defp normalize_term_key(key), do: inspect(key)

  defp uuid_string_list?(values) when is_list(values) do
    values != [] and Enum.all?(values, fn value -> is_binary(value) and uuid?(value) end)
  end

  defp uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> true
      :error -> false
    end
  end
end
