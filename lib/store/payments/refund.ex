defmodule Store.Payments.Refund do
  @moduledoc """
  Durable refund evidence resource with idempotent request identity.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Payments.Types.RefundState do
      allow_nil?(false)
      default(:requested)
      public?(true)
    end

    attribute :provider, :string do
      allow_nil?(false)
      default("stripe")
      public?(true)
    end

    attribute :provider_refund_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :requested_amount_minor, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(true)
    end

    attribute :currency, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :reason, :string do
      allow_nil?(false)
      default("unspecified")
      public?(true)
    end

    attribute :scope_hash, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :scope_kind, Store.Payments.Types.RefundScopeKind do
      allow_nil?(false)
      default(:partial_refund)
      public?(true)
    end

    attribute :line_item_ids, {:array, :uuid} do
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :requested_by_user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :requested_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    attribute :submitted_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :finalized_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :version, :integer do
      allow_nil?(false)
      default(1)
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

    belongs_to :payment_intent, Store.Payments.PaymentIntent do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  state_machine do
    initial_states([:requested])
    default_initial_state(:requested)

    transitions do
      transition(:mark_submitted, from: :requested, to: :submitted)
      transition(:mark_succeeded, from: [:requested, :submitted], to: :succeeded)
      transition(:mark_failed, from: [:requested, :submitted], to: :failed)
      transition(:cancel, from: [:requested, :submitted], to: :cancelled)
    end
  end

  identities do
    identity(:unique_idempotency_key, [:idempotency_key])
    identity(:unique_provider_refund_id, [:provider, :provider_refund_id])
  end

  actions do
    defaults([:read])

    create :request do
      accept([
        :order_id,
        :payment_intent_id,
        :provider,
        :requested_amount_minor,
        :currency,
        :reason,
        :scope_hash,
        :scope_kind,
        :line_item_ids,
        :idempotency_key,
        :requested_by_user_id,
        :requested_at
      ])

      change(fn changeset, context ->
        requested_by_user_id = Ash.Changeset.get_attribute(changeset, :requested_by_user_id)
        actor_id = context.actor && Map.get(context.actor, :id)

        if is_binary(requested_by_user_id) or is_nil(actor_id) do
          changeset
        else
          Ash.Changeset.change_attribute(changeset, :requested_by_user_id, actor_id)
        end
      end)
    end

    update :mark_submitted do
      require_atomic?(false)
      accept([:provider_refund_id, :submitted_at])
      change({Store.Support.Governance.TransitionState, target: :submitted})
    end

    update :mark_succeeded do
      require_atomic?(false)
      accept([:provider_refund_id, :finalized_at])
      change({Store.Support.Governance.TransitionState, target: :succeeded})
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:finalized_at])
      change({Store.Support.Governance.TransitionState, target: :failed})
    end

    update :cancel do
      require_atomic?(false)
      accept([:finalized_at])
      change({Store.Support.Governance.TransitionState, target: :cancelled})
    end
  end

  postgres do
    table("refunds")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id], name: "refunds_order_id_index")
      index([:payment_intent_id], name: "refunds_payment_intent_id_index")
      index([:state], name: "refunds_state_index")
      index([:provider, :provider_refund_id], name: "refunds_provider_refund_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:request) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end

    policy action_type(:update) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
    end

    policy always() do
      forbid_if(always())
    end
  end
end
