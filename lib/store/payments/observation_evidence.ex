defmodule Store.Payments.ObservationEvidence do
  @moduledoc "Persists immutable provider evidence through the shared PaymentAttempt resource."

  alias Store.Payments.{PaymentAttempt, PaymentIntent}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Support.Governance.Idempotency

  @spec record(PaymentIntent.t(), ProviderObservation.t()) ::
          {:ok, PaymentAttempt.t()} | {:error, term()}
  def record(%PaymentIntent{} = payment_intent, %ProviderObservation{} = observation) do
    attrs = %{
      payment_intent_id: payment_intent.id,
      provider: observation.provider,
      provider_event_id: observation.provider_event_id,
      provider_event_key: provider_event_key(observation),
      attempt_key: observation_key(payment_intent, observation),
      provider_reference: empty_to_nil(observation.provider_reference),
      provider_reference_kind: reference_kind(observation.provider_reference_kind),
      provider_transaction_id: observation.provider_transaction_id,
      observation_source: Atom.to_string(observation.observation_source),
      outcome: Atom.to_string(observation.normalized_outcome),
      raw_provider_status: observation.raw_provider_status,
      amount_minor: observation.amount_minor,
      currency: observation.currency,
      provider_environment: observation.provider_environment,
      provider_occurred_at: observation.provider_occurred_at,
      observed_at: observation.observed_at,
      attempted_at: observation.observed_at,
      payload_sha256: observation.evidence_sha256
    }

    PaymentAttempt
    |> Ash.Changeset.for_create(:record, attrs, context: %{system?: true})
    |> Ash.create(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp observation_key(payment_intent, observation) do
    identity =
      {observation.provider, observation.provider_reference, observation.provider_transaction_id,
       reference_kind(observation.provider_reference_kind), payment_intent.id,
       observation.provider_event_id, observation.observation_source,
       observation.normalized_outcome, observation.raw_provider_status, observation.amount_minor,
       observation.currency, observation.provider_environment, observation.provider_occurred_at}

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(identity, [:deterministic]))
    "provider_observation:" <> Base.encode16(digest, case: :lower)
  end

  defp provider_event_key(%ProviderObservation{provider_event_id: nil}), do: nil

  defp provider_event_key(%ProviderObservation{provider: provider, provider_event_id: id}) do
    Idempotency.provider_event_key(provider, id)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp reference_kind(nil), do: nil
  defp reference_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
end
