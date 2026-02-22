defmodule Store.Admin.AuditLog do
  @moduledoc """
  Append-only audit log evidence for privileged actions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Admin

  attributes do
    uuid_v7_primary_key(:id)

    attribute :actor_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :action, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :resource, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :record_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :request_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :meta, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :payload_sha256, :string do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:actor_id, :action, :resource, :record_id, :request_id, :meta, :payload_sha256])
      change(Store.Admin.Changes.SanitizeAuditMeta)
    end
  end

  postgres do
    table("audit_logs")
    repo(Store.Repo)

    custom_indexes do
      index([:inserted_at], name: "audit_logs_inserted_at_index")
      index([:actor_id], name: "audit_logs_actor_id_index")
      index([:action], name: "audit_logs_action_index")
      index([:resource], name: "audit_logs_resource_index")
      index([:request_id], name: "audit_logs_request_id_index")
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type(:create) do
      access_type(:strict)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
