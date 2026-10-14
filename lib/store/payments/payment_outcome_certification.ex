defmodule Store.Payments.PaymentOutcomeCertification do
  @moduledoc "Durable result of accepting provider evidence through PaymentOutcomeResolver."

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :financial_outcome, Store.Payments.Types.CertifiedPaymentOutcome do
      allow_nil?(false)
      public?(false)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :payment_intent, Store.Payments.PaymentIntent do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :payment_attempt, Store.Payments.PaymentAttempt do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_payment_attempt, [:payment_attempt_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :record do
      public?(false)
      accept([:payment_intent_id, :payment_attempt_id, :financial_outcome])
      upsert?(true)
      upsert_identity(:unique_payment_attempt)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  postgres do
    table("payment_outcome_certifications")
    repo(Store.Repo)

    references do
      reference(:payment_intent, on_delete: :restrict)
      reference(:payment_attempt, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(
        :financial_outcome,
        "payment_outcome_certifications_financial_outcome_check",
        check:
          "financial_outcome IN ('requires_action', 'verified_success', 'verified_terminal_financial_non_success')"
      )
    end

    custom_indexes do
      index([:payment_intent_id], name: "payment_outcome_certifications_intent_index")
    end
  end

  policies do
    policy action(:record) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy action(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
