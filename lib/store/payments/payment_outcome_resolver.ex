defmodule Store.Payments.PaymentOutcomeResolver do
  @moduledoc "Resolves normalized provider evidence into a safe Commerce payment outcome."

  alias Store.Payments.Types.ProviderObservation

  @type outcome ::
          :authoritative_success
          | :verified_terminal_non_success
          | :requires_action
          | :unresolved
          | :reconciliation_required
          | :already_applied_success

  @type finality :: :authoritative_success | :terminal_non_success | :non_terminal | :unknown

  @spec resolve(map(), ProviderObservation.t(), keyword()) :: {:ok, outcome()}
  def resolve(payment_intent, %ProviderObservation{} = observation, opts \\ [])
      when is_map(payment_intent) and is_list(opts) do
    if exact_intent?(payment_intent, observation) do
      resolve_application(payment_intent, observation, opts)
    else
      {:ok, :reconciliation_required}
    end
  end

  defp resolve_application(payment_intent, observation, opts) do
    application = Keyword.get(opts, :payment_application)

    cond do
      exact_application?(payment_intent, application) ->
        {:ok, :already_applied_success}

      conflicting_application?(application) ->
        {:ok, :reconciliation_required}

      true ->
        resolve_finality(observation, opts)
    end
  end

  defp resolve_finality(observation, opts) do
    finality = Keyword.get(opts, :provider_finality, :unknown)
    eligible? = Keyword.get(opts, :eligibility) == :eligible

    case {observation.normalized_outcome, finality, eligible?} do
      {:authoritative_success, :authoritative_success, true} ->
        {:ok, :authoritative_success}

      {:failure_observation, :terminal_non_success, _} ->
        {:ok, :verified_terminal_non_success}

      {:requires_action, :non_terminal, _} ->
        {:ok, :requires_action}

      {outcome, :non_terminal, _} when outcome in [:failure_observation, :unresolved] ->
        {:ok, :unresolved}

      _ ->
        {:ok, :reconciliation_required}
    end
  end

  defp exact_application?(payment_intent, %{payment_intent_id: id, order_id: order_id}) do
    is_binary(id) and id == Map.get(payment_intent, :id) and
      is_binary(order_id) and order_id == Map.get(payment_intent, :order_id)
  end

  defp exact_application?(_payment_intent, _application), do: false

  defp conflicting_application?(%{payment_intent_id: id}) when is_binary(id), do: true
  defp conflicting_application?(_application), do: false

  defp exact_intent?(payment_intent, observation) do
    is_nil(observation.local_payment_intent_id) or
      observation.local_payment_intent_id == Map.get(payment_intent, :id)
  end
end
