defmodule Store.Subscriptions.RenewalCollectionDispatchPolicy do
  @moduledoc "Provider-neutral recovery policy for a reached renewal collection."

  @spec recovery_action(map(), map(), atom(), map()) ::
          :submit | :reconcile | :replay_same_request
  def recovery_action(collection, payment_intent, subscription_status, capabilities)
      when is_map(collection) and is_map(payment_intent) and is_map(capabilities) do
    if Map.get(collection, :dispatch_state) == :may_have_been_reached do
      reached_collection_action(collection, payment_intent, subscription_status, capabilities)
    else
      :submit
    end
  end

  def recovery_action(_collection, _payment_intent, _subscription_status, _capabilities),
    do: :reconcile

  defp reached_collection_action(collection, payment_intent, subscription_status, capabilities) do
    if may_replay_same_request?(collection, payment_intent, subscription_status, capabilities),
      do: :replay_same_request,
      else: :reconcile
  end

  defp may_replay_same_request?(collection, payment_intent, subscription_status, capabilities) do
    Map.get(collection, :financial_outcome) == :unresolved and
      subscription_status not in [:canceled, :expired] and
      Map.get(payment_intent, :state) != :requires_action and
      not present?(Map.get(payment_intent, :provider_payment_id)) and
      present?(Map.get(payment_intent, :provider_request_reference)) and
      Map.get(capabilities, :supports_same_request_replay?, false)
  end

  defp present?(value), do: is_binary(value) and value != ""
end
