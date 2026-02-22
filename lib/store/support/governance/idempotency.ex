defmodule Store.Support.Governance.Idempotency do
  @moduledoc """
  Deterministic idempotency helpers for payment/provider event ingestion.
  """

  @spec provider_event_key(String.t(), String.t()) :: String.t()
  def provider_event_key(provider, provider_event_id)
      when is_binary(provider) and is_binary(provider_event_id) do
    "#{provider}:#{provider_event_id}"
  end

  @spec payload_hash(term()) :: String.t() | nil
  def payload_hash(payload)

  def payload_hash(nil), do: nil

  def payload_hash(payload) when is_binary(payload) do
    hash_sha256(payload)
  end

  def payload_hash(payload) when is_map(payload) or is_list(payload) do
    payload
    |> Jason.encode!()
    |> hash_sha256()
  end

  def payload_hash(payload), do: payload |> inspect() |> hash_sha256()

  defp hash_sha256(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
