defmodule Store.Payments.ProviderObservationTest do
  use ExUnit.Case, async: true

  alias Store.Payments.PaymentIntent
  alias Store.Payments.Types.ProviderObservation

  test "eligibility requires exact provider reference amount and currency" do
    intent = %PaymentIntent{
      id: "intent-1",
      provider: :stripe,
      provider_payment_id: "pi_1",
      amount_received_minor: 2500,
      currency: "USD"
    }

    observation = %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_1",
      provider_reference_kind: :payment_intent,
      provider_transaction_id: "pi_1",
      observation_source: :verification,
      amount_minor: 2500,
      currency: "USD",
      provider_environment: "test",
      raw_provider_status: "succeeded",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :authoritative_success
    }

    assert :eligible =
             ProviderObservation.validate_target(intent, observation,
               provider_environment: "test"
             )

    assert {:error, :environment_unverified} =
             ProviderObservation.validate_target(intent, observation)

    assert {:error, :amount_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | amount_minor: 2499})

    assert {:error, :currency_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | currency: "EUR"})

    assert {:error, :provider_reference_mismatch} =
             ProviderObservation.validate_target(intent, %{
               observation
               | provider_reference: "pi_2"
             })

    assert {:error, :provider_reference_kind_mismatch} =
             ProviderObservation.validate_target(
               intent,
               %{observation | provider_reference_kind: :checkout_session},
               provider_environment: "test"
             )

    assert {:error, :provider_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | provider: :paystack})

    assert {:error, :provider_transaction_mismatch} =
             ProviderObservation.validate_target(intent, %{
               observation
               | provider_transaction_id: "pi_other"
             })

    assert {:error, :provider_transaction_unverified} =
             ProviderObservation.validate_target(
               intent,
               %{observation | provider_transaction_id: nil},
               provider_environment: "test"
             )

    assert {:error, :environment_mismatch} =
             ProviderObservation.validate_target(
               intent,
               %{observation | provider_environment: "test"},
               provider_environment: "live"
             )
  end

  test "Stripe success requires a known matching expected environment" do
    intent = %PaymentIntent{
      id: "intent-1",
      provider: :stripe,
      provider_payment_id: "pi_1",
      amount_received_minor: 2500,
      currency: "USD"
    }

    observation = %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_1",
      provider_reference_kind: :payment_intent,
      provider_transaction_id: "pi_1",
      observation_source: :verification,
      amount_minor: 2500,
      currency: "USD",
      provider_environment: "test",
      raw_provider_status: "succeeded",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :authoritative_success
    }

    assert :eligible =
             ProviderObservation.validate_target(intent, observation,
               provider_environment: "test"
             )

    assert {:error, :environment_mismatch} =
             ProviderObservation.validate_target(intent, observation,
               provider_environment: "live"
             )

    assert {:error, :environment_unverified} =
             ProviderObservation.validate_target(intent, observation)
  end

  test "a durable provider request reference can bind verification without a returned transaction ID" do
    intent = %PaymentIntent{
      id: "intent-1",
      provider: :paystack,
      provider_request_reference: "renewal-018f4a1c7b2d7a918f0162e0a3c4b5d6",
      amount_received_minor: 25_750,
      currency: "ZAR"
    }

    verified = %ProviderObservation{
      provider: :paystack,
      provider_reference: intent.provider_request_reference,
      provider_reference_kind: :transaction_reference,
      provider_transaction_id: "2046671778",
      local_payment_intent_id: intent.id,
      observation_source: :verification,
      amount_minor: 25_750,
      currency: "ZAR",
      raw_provider_status: "success",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :authoritative_success
    }

    assert :eligible = ProviderObservation.validate_target(intent, verified)

    assert {:error, :provider_transaction_unverified} =
             ProviderObservation.validate_target(intent, %{
               verified
               | provider_transaction_id: nil,
                 observation_source: :direct_response
             })
  end

  test "unresolved and unknown outcomes never qualify as success" do
    intent = %PaymentIntent{
      id: "intent-1",
      provider: :stripe,
      provider_payment_id: "pi_1",
      amount_received_minor: 2500,
      currency: "USD"
    }

    observation = %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_1",
      provider_reference_kind: :payment_intent,
      provider_transaction_id: "pi_1",
      observation_source: :verification,
      amount_minor: 2500,
      currency: "USD",
      provider_environment: "test",
      raw_provider_status: "processing",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :unresolved
    }

    assert {:error, :observation_not_authoritative_success} =
             ProviderObservation.validate_target(intent, observation,
               provider_environment: "test"
             )
  end
end
