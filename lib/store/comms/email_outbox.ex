defmodule Store.Comms.EmailOutbox do
  @moduledoc """
  Durable outbox row for transactional email delivery.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Comms

  attributes do
    uuid_v7_primary_key(:id)

    attribute :template_kind, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :to_email, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :subject, :string do
      allow_nil?(false)
      default("")
      public?(true)
    end

    attribute :body_text, :string do
      allow_nil?(false)
      default("")
      public?(true)
    end

    attribute :body_html, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :state, Store.Comms.Types.EmailOutboxState do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :attempt_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :last_error, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :sent_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_idempotency_key, [:idempotency_key])
    identity(:unique_order_template_kind, [:order_id, :template_kind])
  end

  actions do
    defaults([:read])

    read :get_for_system do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :enqueue do
      accept([
        :order_id,
        :template_kind,
        :to_email,
        :subject,
        :body_text,
        :body_html,
        :idempotency_key,
        :state,
        :attempt_count
      ])

      upsert?(true)
      upsert_identity(:unique_order_template_kind)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_processing do
      accept([:attempt_count])
      change(set_attribute(:state, :processing))
      change(set_attribute(:last_error, nil))
    end

    update :mark_sent do
      accept([:attempt_count, :sent_at])
      change(set_attribute(:state, :sent))
      change(set_attribute(:last_error, nil))
    end

    update :mark_failed do
      accept([:attempt_count, :last_error])
      change(set_attribute(:state, :failed))
    end
  end

  code_interface do
    define(:get_for_system, action: :get_for_system, args: [:id])
  end

  postgres do
    table("email_outboxes")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id], name: "email_outboxes_order_id_index")
      index([:state], name: "email_outboxes_state_index")
      index([:template_kind], name: "email_outboxes_template_kind_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(context_equals(:system?, true))
    end

    policy action([:enqueue, :mark_processing, :mark_sent, :mark_failed, :get_for_system]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
