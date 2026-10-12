defmodule Store.Payments.PaymentOutcomeResolverTest do
  use ExUnit.Case, async: true

  alias Store.Payments.PaymentOutcomeResolver
  alias Store.Payments.Types.ProviderObservation

  defp observation(outcome, raw_status, overrides \\ %{}) do
    struct!(
      ProviderObservation,
      Map.merge(
        %{
          provider: :stripe,
          provider_reference: "pi_123",
          provider_reference_kind: :payment_intent,
          provider_transaction_id: "pi_123",
          local_payment_intent_id: "intent-1",
          observation_source: :webhook,
          normalized_outcome: outcome,
          raw_provider_status: raw_status,
          amount_minor: 2500,
          currency: "USD",
          provider_environment: "test",
          observed_at: DateTime.utc_now()
        },
        overrides
      )
    )
  end

  test "eligible authoritative success resolves as success" do
    assert {:ok, :authoritative_success} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:authoritative_success, "succeeded"),
               eligibility: :eligible,
               provider_finality: :authoritative_success
             )
  end

  test "exact applied payment application takes precedence" do
    application = %{order_id: "order-1", payment_intent_id: "intent-1"}

    assert {:ok, :already_applied_success} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1", order_id: "order-1"},
               observation(:failure_observation, "requires_payment_method"),
               payment_application: application,
               provider_finality: :non_terminal
             )
  end

  test "an application for another payment intent requires reconciliation" do
    application = %{order_id: "order-1", payment_intent_id: "intent-a"}

    assert {:ok, :reconciliation_required} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-b", order_id: "order-1"},
               observation(:authoritative_success, "succeeded"),
               eligibility: :eligible,
               provider_finality: :authoritative_success,
               payment_application: application
             )
  end

  test "terminal failure is resolved only when the provider certifies finality" do
    assert {:ok, :verified_terminal_non_success} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:failure_observation, "canceled"),
               provider_finality: :terminal_non_success
             )
  end

  test "retryable failure and action observations remain unresolved" do
    assert {:ok, :unresolved} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:failure_observation, "requires_payment_method"),
               provider_finality: :non_terminal
             )

    assert {:ok, :requires_action} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:requires_action, "requires_action"),
               provider_finality: :non_terminal
             )
  end

  test "untrusted success and unknown finality require reconciliation" do
    assert {:ok, :reconciliation_required} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:authoritative_success, "succeeded"),
               eligibility: {:error, :amount_mismatch},
               provider_finality: :authoritative_success
             )

    assert {:ok, :reconciliation_required} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:unknown_or_contradictory, "future_status"),
               provider_finality: :unknown
             )
  end

  test "certified terminal and success facts resolve to reconciliation regardless of current fact" do
    terminal = observation(:failure_observation, "canceled")
    success = observation(:authoritative_success, "succeeded")

    options = [
      eligibility: :eligible,
      provider_finality: :authoritative_success,
      terminal_non_success_evidence?: true,
      authoritative_success_evidence?: true
    ]

    assert {:ok, :reconciliation_required} =
             PaymentOutcomeResolver.resolve(%{id: "intent-1"}, success, options)

    assert {:ok, :reconciliation_required} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               terminal,
               Keyword.put(options, :provider_finality, :terminal_non_success)
             )
  end

  test "persisted nonterminal failure does not block an eligible success" do
    assert {:ok, :authoritative_success} =
             PaymentOutcomeResolver.resolve(
               %{id: "intent-1"},
               observation(:authoritative_success, "succeeded"),
               eligibility: :eligible,
               provider_finality: :authoritative_success,
               authoritative_success_evidence?: true
             )
  end

  test "opposite observation arrival order does not change the resolved outcome" do
    failure = observation(:failure_observation, "requires_payment_method")
    success = observation(:authoritative_success, "succeeded")

    resolve = fn observations ->
      Enum.reduce(observations, :unresolved, fn {evidence, finality, eligibility}, current ->
        application =
          if current == :authoritative_success do
            %{order_id: "order-1", payment_intent_id: "intent-1"}
          end

        {:ok, resolved} =
          PaymentOutcomeResolver.resolve(%{id: "intent-1", order_id: "order-1"}, evidence,
            provider_finality: finality,
            eligibility: eligibility,
            payment_application: application
          )

        if resolved == :already_applied_success, do: :authoritative_success, else: resolved
      end)
    end

    assert resolve.([
             {failure, :non_terminal, nil},
             {success, :authoritative_success, :eligible}
           ]) == :authoritative_success

    assert resolve.([
             {success, :authoritative_success, :eligible},
             {failure, :non_terminal, nil}
           ]) == :authoritative_success
  end
end
