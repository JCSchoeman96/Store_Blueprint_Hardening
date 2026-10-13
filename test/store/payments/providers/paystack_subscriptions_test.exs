defmodule Store.Payments.Providers.PaystackSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Store.Payments.PaymentOutcomeResolver
  alias Store.Payments.Providers
  alias Store.Payments.Providers.Paystack
  alias Store.Payments.Types.{ProviderObservation, RenewalCollectionChargeRequest}
  alias Store.Subscriptions.RenewalCollectionDispatchPolicy

  test "paystack recurring capability is disabled and unsupported contracts error explicitly" do
    capabilities = Paystack.capabilities()
    assert capabilities.supports_provider_managed_subscriptions? == false
    assert capabilities.supports_merchant_initiated_charges? == false

    assert {:error, verify_error} = Paystack.verify_webhook(%{}, "{}", [])
    assert verify_error.code == "PAYMENT_PROVIDER_VERIFICATION_FAILED"

    assert {:error, normalize_error} = Paystack.normalize_webhook(%{})
    assert normalize_error.code == "PAYMENT_PAYLOAD_INVALID"
  end

  test "renewal collection identity maps to a Paystack-valid request reference" do
    collection_id = "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d6"
    internal_identity = "renewal-collection:" <> collection_id

    assert {:ok, provider_reference} =
             Providers.renewal_collection_request_reference(:paystack, collection_id)

    assert provider_reference == "renewal-018f4a1c7b2d7a918f0162e0a3c4b5d6"
    assert byte_size(provider_reference) == 40
    assert provider_reference =~ ~r/\A[a-zA-Z0-9.=-]+\z/
    refute provider_reference == internal_identity
    refute String.contains?(provider_reference, ":")
  end

  test "the generic renewal request carries exact ZAR money and opaque Paystack evidence" do
    collection_id = "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d6"
    internal_identity = "renewal-collection:" <> collection_id

    {:ok, provider_reference} =
      Providers.renewal_collection_request_reference(:paystack, collection_id)

    request = %RenewalCollectionChargeRequest{
      internal_collection_identity: internal_identity,
      provider_request_reference: provider_reference,
      collection_attempt_id: collection_id,
      payment_intent_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d7",
      renewal_attempt_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d8",
      order_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d9",
      subscription_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5da",
      amount_minor: 25_750,
      currency: "ZAR",
      renewal_key: "sub:subscription-123:end:2026-10-13T00:00:00Z",
      provider_customer_ref: "CUS_123",
      provider_customer_email: "customer@example.test",
      provider_credential_ref: "AUTH_reusable_123"
    }

    assert request.amount_minor == 25_750
    assert request.currency == "ZAR"
    assert request.provider_credential_ref == "AUTH_reusable_123"
    assert request.provider_customer_ref == "CUS_123"
    assert request.provider_customer_email == "customer@example.test"
    assert request.provider_request_reference == provider_reference
    refute request.provider_request_reference =~ "subscription-123"
    refute request.provider_request_reference == request.internal_collection_identity
  end

  test "an ambiguous PayStack request reconciles its exact reference before any new collection" do
    collection_id = "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d6"

    {:ok, provider_reference} =
      Providers.renewal_collection_request_reference(:paystack, collection_id)

    request = %RenewalCollectionChargeRequest{
      internal_collection_identity: "renewal-collection:" <> collection_id,
      provider_request_reference: provider_reference,
      collection_attempt_id: collection_id,
      payment_intent_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d7",
      renewal_attempt_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d8",
      order_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d9",
      subscription_id: "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5da",
      amount_minor: 25_750,
      currency: "ZAR",
      renewal_key: "sub:subscription-123:end:2026-10-13T00:00:00Z",
      provider_customer_ref: "CUS_123",
      provider_credential_ref: "AUTH_reusable_123"
    }

    success = %ProviderObservation{
      provider: :paystack,
      provider_reference: provider_reference,
      provider_reference_kind: :transaction_reference,
      provider_transaction_id: "2046671778",
      local_payment_intent_id: request.payment_intent_id,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "success",
      amount_minor: request.amount_minor,
      currency: request.currency,
      observed_at: DateTime.utc_now()
    }

    provider_state =
      Agent.start_link(fn -> %{used_references: MapSet.new(), occurrences: 0, post_calls: 0} end)
      |> elem(1)

    submit = fn charge_request ->
      Agent.get_and_update(provider_state, fn state ->
        if MapSet.member?(state.used_references, charge_request.provider_request_reference) do
          {{:error, :duplicate_reference}, %{state | post_calls: state.post_calls + 1}}
        else
          updated = %{
            state
            | used_references:
                MapSet.put(state.used_references, charge_request.provider_request_reference),
              occurrences: state.occurrences + 1,
              post_calls: state.post_calls + 1
          }

          {{:error, :timeout}, updated}
        end
      end)
    end

    verify = fn exact_reference ->
      assert exact_reference == request.provider_request_reference
      {:ok, success}
    end

    assert {:error, :timeout} = submit.(request)

    renewal_attempt = %{id: request.renewal_attempt_id}

    collection = %{
      id: request.collection_attempt_id,
      dispatch_state: :may_have_been_reached,
      financial_outcome: :unresolved
    }

    payment_intent = %{
      id: request.payment_intent_id,
      provider: :paystack,
      provider_payment_id: nil,
      provider_request_reference: request.provider_request_reference,
      order_id: request.order_id,
      amount_received_minor: request.amount_minor,
      currency: request.currency,
      state: :submitted
    }

    recovery_action =
      RenewalCollectionDispatchPolicy.recovery_action(
        collection,
        payment_intent,
        :active,
        Paystack.capabilities()
      )

    assert recovery_action == :reconcile

    pending = %{
      success
      | provider_transaction_id: nil,
        normalized_outcome: :unresolved,
        raw_provider_status: "pending"
    }

    assert {:ok, :unresolved} =
             PaymentOutcomeResolver.resolve(payment_intent, pending,
               provider_finality: :non_terminal
             )

    assert recovery_action == :reconcile

    recovery_result =
      case recovery_action do
        :reconcile -> verify.(payment_intent.provider_request_reference)
        :replay_same_request -> submit.(request)
        :submit -> submit.(request)
      end

    assert {:ok, observation} = recovery_result
    assert ProviderObservation.validate_target(payment_intent, observation) == :eligible
    assert renewal_attempt.id == request.renewal_attempt_id
    assert collection.id == request.collection_attempt_id
    assert payment_intent.id == request.payment_intent_id
    assert payment_intent.provider_request_reference == provider_reference

    assert {:ok, :authoritative_success} =
             PaymentOutcomeResolver.resolve(payment_intent, observation,
               eligibility: :eligible,
               provider_finality: :authoritative_success
             )

    terminal = %{
      observation
      | normalized_outcome: :failure_observation,
        raw_provider_status: "failed",
        provider_transaction_id: "2046671778"
    }

    assert {:ok, :verified_terminal_non_success} =
             PaymentOutcomeResolver.resolve(payment_intent, terminal,
               eligibility: :eligible,
               provider_finality: :terminal_non_success
             )

    assert %{post_calls: 1, occurrences: 1} = Agent.get(provider_state, & &1)

    assert {:error, :duplicate_reference} = submit.(request)
    assert %{post_calls: 2, occurrences: 1} = Agent.get(provider_state, & &1)

    Agent.stop(provider_state)
  end
end
