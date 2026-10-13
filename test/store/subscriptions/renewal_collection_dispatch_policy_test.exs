defmodule Store.Subscriptions.RenewalCollectionDispatchPolicyTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.RenewalCollectionDispatchPolicy

  for subscription_status <- [:active, :past_due] do
    test "an ambiguous reached collection for #{subscription_status} reconciles its exact request" do
      collection = %{
        id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d6",
        dispatch_state: :may_have_been_reached,
        financial_outcome: :unresolved
      }

      payment_intent = %{
        id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d7",
        provider_payment_id: nil,
        provider_request_reference: "renewal-018f4a1c7b2d7a918f0162e0a3c4b5d6",
        state: :submitted
      }

      capabilities = %{
        supports_same_request_replay?: false,
        supports_transaction_observation?: true
      }

      assert RenewalCollectionDispatchPolicy.recovery_action(
               collection,
               payment_intent,
               unquote(subscription_status),
               capabilities
             ) == :reconcile

      assert payment_intent.provider_request_reference ==
               "renewal-018f4a1c7b2d7a918f0162e0a3c4b5d6"
    end
  end

  test "same-request replay requires an explicit provider capability and exact reference" do
    collection = %{
      dispatch_state: :may_have_been_reached,
      financial_outcome: :unresolved
    }

    payment_intent = %{
      provider_payment_id: nil,
      provider_request_reference: "stripe-request-identity",
      state: :submitted
    }

    assert RenewalCollectionDispatchPolicy.recovery_action(
             collection,
             payment_intent,
             :active,
             %{supports_same_request_replay?: true}
           ) == :replay_same_request

    assert RenewalCollectionDispatchPolicy.recovery_action(
             collection,
             %{payment_intent | provider_request_reference: nil},
             :active,
             %{supports_same_request_replay?: true}
           ) == :reconcile
  end
end
