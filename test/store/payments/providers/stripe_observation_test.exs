defmodule Store.Payments.Providers.StripeObservationTest do
  use ExUnit.Case, async: true

  alias Store.Payments.Providers
  alias Store.Payments.Providers.Stripe
  alias Store.Payments.Types.ProviderObservation
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "retrieves a provider payment and normalizes its evidence" do
    StripeAPIStub.stub_payment_observation("pi_known", %{
      "amount" => 2500,
      "amount_received" => 2500,
      "currency" => "usd",
      "id" => "pi_known",
      "metadata" => %{"local_intent_id" => "local-1"},
      "status" => "succeeded"
    })

    assert {:ok, %ProviderObservation{} = observation} =
             Providers.observe_payment(:stripe, %{provider_reference: "pi_known"})

    assert observation.provider == :stripe
    assert observation.provider_reference == "pi_known"
    assert observation.provider_transaction_id == "pi_known"
    assert observation.local_payment_intent_id == "local-1"
    assert observation.normalized_outcome == :authoritative_success
    assert observation.amount_minor == 2500
    assert observation.currency == "USD"
    assert observation.provider_environment == "test"
    assert observation.observation_source == :verification
    assert %DateTime{} = observation.observed_at
  end

  test "unknown provider statuses remain explicitly inconclusive" do
    StripeAPIStub.stub_payment_observation("pi_known", %{
      "amount" => 2500,
      "currency" => "usd",
      "id" => "pi_known",
      "status" => "future_status"
    })

    assert {:ok, observation} =
             Stripe.observe_payment(%{provider_reference: "pi_known"}, [])

    assert observation.normalized_outcome == :unknown_or_contradictory
  end

  test "providers without read support fail explicitly" do
    assert {:error, error} = Providers.observe_payment(:paystack, %{provider_reference: "ref"})
    assert error.code == "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED"
  end

  test "unknown providers fail closed before any provider request" do
    assert {:error, error} =
             Providers.observe_payment("future_provider", %{provider_reference: "ref"})

    assert error.code == "PAYMENT_PROVIDER_UNSUPPORTED"
  end
end
