defmodule Store.Payments.WebhookReceipt do
  @moduledoc """
  Receipt-first webhook evidence with idempotent duplicate NOOP semantics.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :provider, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :payload_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_idempotency_key, [:idempotency_key])
  end

  actions do
    defaults([:read])

    create :ingest do
      accept([:provider, :idempotency_key, :payload_sha256, :received_at])

      upsert?(true)
      upsert_identity(:unique_idempotency_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  postgres do
    table("webhook_receipts")
    repo(Store.Repo)

    custom_indexes do
      index([:provider], name: "webhook_receipts_provider_index")
      index([:received_at], name: "webhook_receipts_received_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:ingest) do
      access_type(:strict)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
