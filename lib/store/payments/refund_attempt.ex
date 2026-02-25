defmodule Store.Payments.RefundAttempt do
  @moduledoc """
  Immutable provider interaction evidence for refund processing attempts.
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

    attribute :provider_refund_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :outcome, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :error_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :error_message, :string do
      allow_nil?(true)
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

    attribute :sequence_no, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :refund, Store.Payments.Refund do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_refund_sequence_no, [:refund_id, :sequence_no])
    identity(:unique_provider_event_key, [:provider_event_key])
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :refund_id,
        :provider,
        :provider_event_id,
        :provider_event_key,
        :provider_refund_id,
        :outcome,
        :error_code,
        :error_message,
        :payload_sha256,
        :attempted_at,
        :sequence_no
      ])
    end
  end

  postgres do
    table("refund_attempts")
    repo(Store.Repo)

    custom_indexes do
      index([:refund_id], name: "refund_attempts_refund_id_index")
      index([:provider_event_key], name: "refund_attempts_provider_event_key_index")
      index([:attempted_at], name: "refund_attempts_attempted_at_index")
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
