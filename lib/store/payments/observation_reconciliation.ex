defmodule Store.Payments.ObservationReconciliation do
  @moduledoc "Reads one known provider transaction and records its evidence."

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.Inputs.ObservePaymentIntentInput
  alias Store.Payments.{ObservationEvidence, PaymentAttempt, PaymentIntent, Providers}
  alias Store.Payments.Types.ProviderObservation
  alias Store.Support.Errors.Error

  @type result :: %{
          payment_intent: PaymentIntent.t(),
          observation: ProviderObservation.t(),
          evidence: PaymentAttempt.t(),
          eligibility: :eligible | {:error, atom()}
        }

  @spec observe_payment_intent(ObservePaymentIntentInput.t()) ::
          {:ok, result()} | {:error, term()}
  def observe_payment_intent(%ObservePaymentIntentInput{} = input) do
    payment_intent_id = input.payment_intent_id

    with {:ok, payment_intent} <- fetch_payment_intent(payment_intent_id),
         {:ok, provider_identity} <- provider_identity(payment_intent),
         {:ok, provider_environment} <- Providers.expected_environment(payment_intent.provider),
         {:ok, observation} <-
           Providers.observe_payment(
             payment_intent.provider,
             provider_identity
           ),
         observation <- %{observation | local_payment_intent_id: payment_intent.id},
         {:ok, %PaymentAttempt{} = attempt} <-
           ObservationEvidence.record(payment_intent, observation) do
      {:ok,
       %{
         payment_intent: payment_intent,
         observation: observation,
         evidence: attempt,
         eligibility:
           ProviderObservation.validate_target(
             payment_intent,
             observation,
             provider_environment: provider_environment
           )
       }}
    end
  end

  defp fetch_payment_intent(id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^id))

    case Ash.read(query, domain: Store.Payments, authorize?: false) do
      {:ok, [%PaymentIntent{} = payment_intent]} ->
        {:ok, payment_intent}

      {:ok, []} ->
        {:error, Error.new("NOT_FOUND", "payment intent was not found")}

      {:ok, _multiple} ->
        {:error, Error.new("INTERNAL_ERROR", "payment intent id returned multiple records")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_identity(%PaymentIntent{} = payment_intent) do
    {reference, kind} =
      case {payment_intent.purpose, payment_intent.provider_payment_id,
            payment_intent.provider_session_id} do
        {:subscription_payment_method_update, payment_id, _session_id}
        when is_binary(payment_id) and payment_id != "" ->
          {payment_id, :setup_intent}

        {_purpose, payment_id, _session_id} when is_binary(payment_id) and payment_id != "" ->
          {payment_id, :payment_intent}

        {_purpose, _payment_id, session_id} when is_binary(session_id) and session_id != "" ->
          {session_id, :checkout_session}

        _ ->
          {nil, nil}
      end

    if is_binary(reference) do
      {:ok, %{provider_reference: reference, provider_reference_kind: kind}}
    else
      {:error,
       Error.new(
         "PAYMENT_EVENT_UNVERIFIED",
         "payment intent has no provider reference for observation"
       )}
    end
  end
end
