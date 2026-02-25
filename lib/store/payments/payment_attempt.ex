defmodule Store.Payments.PaymentAttempt do
  @moduledoc """
  Immutable provider interaction evidence for payment intent processing attempts.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :provider, :string do
      allow_nil?(false)
      default("stripe")
      public?(true)
    end

    attribute :provider_event_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_event_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :attempt_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :outcome, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :payload_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :attempted_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :payment_intent, Store.Payments.PaymentIntent do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_provider_event_key, [:provider_event_key])
    identity(:unique_attempt_key, [:attempt_key])
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :payment_intent_id,
        :provider,
        :provider_event_id,
        :provider_event_key,
        :attempt_key,
        :outcome,
        :payload_sha256,
        :attempted_at
      ])

      upsert?(true)
      upsert_identity(:unique_attempt_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  postgres do
    table("payment_attempts")
    repo(Store.Repo)

    custom_indexes do
      index([:payment_intent_id], name: "payment_attempts_payment_intent_id_index")
      index([:attempted_at], name: "payment_attempts_attempted_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:record) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
