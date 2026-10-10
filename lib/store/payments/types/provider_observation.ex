defmodule Store.Payments.Types.ProviderObservation do
  @moduledoc """
  Immutable, provider-independent facts returned by a provider read or delivered
  through a verified provider event.
  """

  @enforce_keys [
    :provider,
    :provider_reference,
    :observation_source,
    :normalized_outcome,
    :raw_provider_status,
    :amount_minor,
    :currency,
    :observed_at
  ]
  defstruct [
    :provider,
    :provider_reference,
    :provider_transaction_id,
    :local_payment_intent_id,
    :observation_source,
    :normalized_outcome,
    :raw_provider_status,
    :amount_minor,
    :currency,
    :provider_environment,
    :provider_occurred_at,
    :observed_at,
    :provider_customer_ref,
    :provider_payment_method_ref,
    :provider_event_id,
    :evidence_sha256,
    :metadata
  ]

  @type outcome ::
          :unresolved
          | :requires_action
          | :failure_observation
          | :authoritative_success
          | :reversal_observation
          | :unknown_or_contradictory

  @type source :: :direct_response | :webhook | :verification | :reconciliation | :operator

  @type t :: %__MODULE__{
          provider: atom() | String.t(),
          provider_reference: String.t(),
          provider_transaction_id: String.t() | nil,
          local_payment_intent_id: String.t() | nil,
          observation_source: source(),
          normalized_outcome: outcome(),
          raw_provider_status: String.t(),
          amount_minor: non_neg_integer() | nil,
          currency: String.t() | nil,
          provider_environment: String.t() | nil,
          provider_occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t(),
          provider_customer_ref: String.t() | nil,
          provider_payment_method_ref: String.t() | nil,
          provider_event_id: String.t() | nil,
          evidence_sha256: String.t() | nil,
          metadata: map() | nil
        }

  @spec validate_target(map(), t(), keyword()) :: :eligible | {:error, atom()}
  def validate_target(payment_intent, %__MODULE__{} = observation, opts \\ []) do
    with :ok <- validate_provider(payment_intent, observation),
         :ok <- validate_reference(payment_intent, observation),
         :ok <- validate_transaction(payment_intent, observation),
         :ok <- validate_amount(payment_intent, observation),
         :ok <- validate_currency(payment_intent, observation),
         :ok <- validate_environment(observation, opts),
         :ok <- validate_outcome(observation) do
      :eligible
    end
  end

  defp validate_provider(payment_intent, observation) do
    if normalize_provider(Map.get(payment_intent, :provider)) ==
         normalize_provider(observation.provider),
       do: :ok,
       else: {:error, :provider_mismatch}
  end

  defp validate_reference(payment_intent, observation) do
    expected_reference =
      Map.get(payment_intent, :provider_payment_id) ||
        Map.get(payment_intent, :provider_session_id)

    if is_binary(expected_reference) and expected_reference == observation.provider_reference,
      do: :ok,
      else: {:error, :provider_reference_mismatch}
  end

  defp validate_transaction(payment_intent, observation) do
    expected_transaction = Map.get(payment_intent, :provider_payment_id)

    if is_nil(expected_transaction) or is_nil(observation.provider_transaction_id) or
         expected_transaction == observation.provider_transaction_id,
       do: :ok,
       else: {:error, :provider_transaction_mismatch}
  end

  defp validate_amount(payment_intent, observation) do
    expected_amount = Map.get(payment_intent, :amount_received_minor)

    if is_integer(observation.amount_minor) and observation.amount_minor == expected_amount,
      do: :ok,
      else: {:error, :amount_mismatch}
  end

  defp validate_currency(payment_intent, observation) do
    expected_currency = Map.get(payment_intent, :currency) |> to_string() |> String.upcase()

    if is_binary(observation.currency) and
         String.upcase(observation.currency) == expected_currency,
       do: :ok,
       else: {:error, :currency_mismatch}
  end

  defp validate_environment(observation, opts) do
    case Keyword.get(opts, :provider_environment) do
      nil -> :ok
      expected when expected == observation.provider_environment -> :ok
      _expected -> {:error, :environment_mismatch}
    end
  end

  defp validate_outcome(%__MODULE__{normalized_outcome: :authoritative_success}), do: :ok
  defp validate_outcome(_observation), do: {:error, :observation_not_authoritative_success}

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when is_binary(provider), do: String.downcase(provider)
  defp normalize_provider(_provider), do: nil
end
