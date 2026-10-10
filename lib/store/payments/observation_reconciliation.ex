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
         {:ok, provider_reference} <- provider_reference(payment_intent),
         {:ok, observation} <-
           Providers.observe_payment(
             payment_intent.provider,
             %{provider_reference: provider_reference}
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
             input
             |> Map.from_struct()
             |> Keyword.new()
             |> Keyword.take([:provider_environment])
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

  defp provider_reference(%PaymentIntent{} = payment_intent) do
    case payment_intent.provider_payment_id || payment_intent.provider_session_id do
      reference when is_binary(reference) and reference != "" ->
        {:ok, reference}

      _ ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "payment intent has no provider reference for observation"
         )}
    end
  end
end
