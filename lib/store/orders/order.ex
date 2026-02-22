defmodule Store.Orders.Order do
  @moduledoc """
  Order lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    domain: Store.Orders

  attributes do
    uuid_v7_primary_key(:id)

    attribute :state, Store.Orders.Types.OrderState do
      allow_nil?(false)
      default(:pending_payment)
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

  actions do
    defaults([:read])

    create :create do
      accept([])
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
    end
  end
end
