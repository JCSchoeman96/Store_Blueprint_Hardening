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
      observation_source: :verification,
      amount_minor: 2500,
      currency: "USD",
      raw_provider_status: "succeeded",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :authoritative_success
    }

    assert :eligible = ProviderObservation.validate_target(intent, observation)

    assert {:error, :amount_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | amount_minor: 2499})

    assert {:error, :currency_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | currency: "EUR"})

    assert {:error, :provider_reference_mismatch} =
             ProviderObservation.validate_target(intent, %{
               observation
               | provider_reference: "pi_2"
             })

    assert {:error, :provider_mismatch} =
             ProviderObservation.validate_target(intent, %{observation | provider: :paystack})

    assert {:error, :provider_transaction_mismatch} =
             ProviderObservation.validate_target(intent, %{
               observation
               | provider_transaction_id: "pi_other"
             })

    assert {:error, :environment_mismatch} =
             ProviderObservation.validate_target(
               intent,
               %{observation | provider_environment: "test"},
               provider_environment: "live"
             )
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
      observation_source: :verification,
      amount_minor: 2500,
      currency: "USD",
      raw_provider_status: "processing",
      observed_at: DateTime.utc_now(),
      normalized_outcome: :unresolved
    }

    assert {:error, :observation_not_authoritative_success} =
             ProviderObservation.validate_target(intent, observation)
  end
end
