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
             Providers.observe_payment(:stripe, %{
               provider_reference: "pi_known",
               provider_reference_kind: :payment_intent
             })

    assert observation.provider == :stripe
    assert observation.provider_reference == "pi_known"
    assert observation.provider_reference_kind == :payment_intent
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
             Stripe.observe_payment(
               %{provider_reference: "pi_known", provider_reference_kind: :payment_intent},
               []
             )

    assert observation.normalized_outcome == :unknown_or_contradictory
  end

  test "provider livemode is retained for comparison with trusted server environment" do
    StripeAPIStub.stub_payment_observation("pi_live", %{
      "amount" => 2500,
      "amount_received" => 2500,
      "currency" => "usd",
      "id" => "pi_live",
      "livemode" => true,
      "status" => "succeeded"
    })

    assert {:ok, observation} =
             Stripe.observe_payment(
               %{provider_reference: "pi_live", provider_reference_kind: :payment_intent},
               []
             )

    assert observation.provider_environment == "live"
    assert {:ok, "test"} = Providers.expected_environment(:stripe)
  end

  test "checkout session identity reads the session and keeps unpaid sessions unresolved" do
    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/checkout/sessions/cs_only"

      StripeAPIStub.json_response(conn, %{
        "amount_total" => 2500,
        "currency" => "usd",
        "id" => "cs_only",
        "livemode" => false,
        "payment_intent" => nil,
        "payment_status" => "unpaid",
        "status" => "open"
      })
    end)

    assert {:ok, observation} =
             Stripe.observe_payment(
               %{provider_reference: "cs_only", provider_reference_kind: :checkout_session},
               []
             )

    assert observation.provider_reference == "cs_only"
    assert observation.provider_transaction_id == nil
    assert observation.normalized_outcome == :unresolved
    assert observation.amount_minor == 2500
    assert observation.currency == "USD"
    assert observation.provider_environment == "test"
  end

  test "checkout session retrieval follows a discovered PaymentIntent and retains session identity" do
    StripeAPIStub.stub_observation(fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v1/checkout/sessions/cs_paid" ->
          StripeAPIStub.json_response(conn, %{
            "amount_total" => 2500,
            "currency" => "usd",
            "id" => "cs_paid",
            "livemode" => false,
            "payment_intent" => "pi_discovered",
            "payment_status" => "paid",
            "status" => "complete"
          })

        "/v1/payment_intents/pi_discovered" ->
          StripeAPIStub.json_response(conn, %{
            "amount" => 2500,
            "amount_received" => 2500,
            "currency" => "usd",
            "id" => "pi_discovered",
            "status" => "succeeded"
          })

        other ->
          flunk("unexpected Stripe observation path: #{other}")
      end
    end)

    assert {:ok, observation} =
             Stripe.observe_payment(
               %{provider_reference: "cs_paid", provider_reference_kind: :checkout_session},
               []
             )

    assert observation.provider_reference == "cs_paid"
    assert observation.provider_transaction_id == "pi_discovered"
    assert observation.normalized_outcome == :authoritative_success
    assert observation.amount_minor == 2500
    assert observation.currency == "USD"
    assert observation.provider_environment == "test"
  end

  test "SetupIntent identity is explicitly unsupported for payment observation" do
    StripeAPIStub.stub_unexpected!("SetupIntent must not use PaymentIntent retrieval")

    assert {:error, error} =
             Stripe.observe_payment(
               %{
                 provider_reference: "seti_method_update",
                 provider_reference_kind: :setup_intent
               },
               []
             )

    assert error.code == "PAYMENT_PROVIDER_OBSERVATION_UNSUPPORTED"
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
