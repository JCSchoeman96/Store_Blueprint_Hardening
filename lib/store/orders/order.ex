defmodule Store.Orders.Order do
  @moduledoc """
  Order lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  alias Store.Support.ID.OrderRef

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Orders.Types.OrderState do
      allow_nil?(false)
      default(:pending_payment)
      public?(true)
    end

    attribute :order_ref, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :user_id, :uuid do
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

  state_machine do
    initial_states([:pending_payment])
    default_initial_state(:pending_payment)

    transitions do
      transition(:mark_paid, from: :pending_payment, to: :paid)
      transition(:mark_payment_failed, from: :pending_payment, to: :payment_failed)
      transition(:cancel, from: :pending_payment, to: :cancelled)
      transition(:mark_refunded, from: :paid, to: :refunded)
    end
  end

  identities do
    identity(:unique_order_ref, [:order_ref])
  end

  actions do
    defaults([:read])

    create :create do
      accept([:order_ref, :user_id])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :order_ref) do
          nil -> Ash.Changeset.change_attribute(changeset, :order_ref, OrderRef.generate())
          _order_ref -> changeset
        end
      end)
    end

    update :mark_paid do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :paid})
    end

    update :mark_payment_failed do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :payment_failed})
    end

    update :cancel do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :cancelled})
    end

    update :mark_refunded do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :refunded})
    end
  end

  postgres do
    table("orders")
    repo(Store.Repo)

    custom_indexes do
      index([:state], name: "orders_state_index")
      index([:order_ref], name: "orders_order_ref_index")
      index([:user_id], name: "orders_user_id_index")
    end
  end

  policies do
    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type(:read) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:cancel) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:mark_paid) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_payment_failed) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_refunded) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))

      authorize_if(
        {Store.Support.Governance.Checks.RoleWithStepUp,
         roles: [:super_admin, :admin], window_minutes: 15}
      )
    end
  end
end
