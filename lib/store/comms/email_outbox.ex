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

    attribute :template_kind, Store.Comms.Types.EmailTemplateKind do
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
      constraints(allow_empty?: true)
      public?(true)
    end

    attribute :body_html, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :template_assigns, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider, Store.Comms.Types.EmailProvider do
      allow_nil?(false)
      default(:swoosh)
      public?(true)
    end

    attribute :provider_message_id, :string do
      allow_nil?(true)
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

    attribute :processing_started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, Store.Orders.Order do
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :refund, Store.Payments.Refund do
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end

    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_idempotency_key, [:idempotency_key])
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

    read :read_for_admin do
      pagination(keyset?: true, required?: false, default_limit: 20, max_page_size: 100)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :enqueue do
      accept([
        :order_id,
        :refund_id,
        :subscription_id,
        :template_kind,
        :to_email,
        :subject,
        :body_text,
        :body_html,
        :template_assigns,
        :idempotency_key,
        :provider,
        :state,
        :attempt_count
      ])

      change(&validate_template_refund_coherence/2)

      upsert?(true)
      upsert_identity(:unique_idempotency_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_sent do
      accept([:provider_message_id, :sent_at])
      change(set_attribute(:state, :sent))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:processing_started_at, nil))
    end

    update :mark_failed do
      accept([:last_error])
      change(set_attribute(:state, :failed))
      change(set_attribute(:processing_started_at, nil))
    end

    update :mark_pending_retry do
      accept([:last_error])
      change(set_attribute(:state, :pending))
      change(set_attribute(:processing_started_at, nil))
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
      index([:state, :inserted_at], name: "email_outboxes_state_inserted_at_index")
      index([:state, :inserted_at, :id], name: "email_outboxes_state_inserted_at_id_index")

      index([:template_kind, :inserted_at],
        name: "email_outboxes_template_kind_inserted_at_index"
      )

      index([:template_kind, :inserted_at, :id],
        name: "email_outboxes_template_kind_inserted_at_id_index"
      )

      index([:refund_id], name: "email_outboxes_refund_id_index")
      index([:subscription_id], name: "email_outboxes_subscription_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
      authorize_if(context_equals(:system?, true))
    end

    policy action([:enqueue, :mark_sent, :mark_failed, :mark_pending_retry, :get_for_system]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp validate_template_refund_coherence(changeset, _context) do
    template_kind = Ash.Changeset.get_attribute(changeset, :template_kind)
    order_id = Ash.Changeset.get_attribute(changeset, :order_id)
    refund_id = Ash.Changeset.get_attribute(changeset, :refund_id)
    subscription_id = Ash.Changeset.get_attribute(changeset, :subscription_id)

    case {reference_shape(order_id, refund_id, subscription_id), template_group(template_kind)} do
      {:order, :order} -> changeset
      {:refund, :refund} -> changeset
      {:subscription, :subscription} -> changeset
      _ -> add_invalid_template_ref_error(changeset)
    end
  end

  defp reference_shape(order_id, refund_id, subscription_id)

  defp reference_shape(order_id, nil, nil) when is_binary(order_id), do: :order

  defp reference_shape(order_id, refund_id, nil)
       when is_binary(order_id) and is_binary(refund_id), do: :refund

  defp reference_shape(nil, nil, subscription_id) when is_binary(subscription_id),
    do: :subscription

  defp reference_shape(_order_id, _refund_id, _subscription_id), do: :invalid

  defp template_group(template_kind)

  defp template_group(template_kind)
       when template_kind in [:order_receipt, :payment_authentication_required],
       do: :order

  defp template_group(template_kind) when template_kind in [:refund_requested, :refund_processed],
    do: :refund

  defp template_group(template_kind) when template_kind in [:renewal_reminder, :access_ended],
    do: :subscription

  defp template_group(_template_kind), do: :invalid

  defp add_invalid_template_ref_error(changeset) do
    Ash.Changeset.add_error(
      changeset,
      field: :template_kind,
      message: "template_kind/order_id/refund_id/subscription_id combination is invalid"
    )
  end
end
