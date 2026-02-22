defmodule Store.Payments.PaymentIntent do
  @moduledoc """
  Payment intent lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Payments

  attributes do
    uuid_v7_primary_key(:id)

    attribute :order_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :state, Store.Payments.Types.PaymentIntentState do
      allow_nil?(false)
      default(:created)
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
    initial_states([:created])
    default_initial_state(:created)

    transitions do
      transition(:submit, from: :created, to: :submitted)
      transition(:mark_succeeded, from: :submitted, to: :succeeded)
      transition(:mark_failed, from: :submitted, to: :failed)
      transition(:cancel, from: :created, to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:order_id])
    end

    update :submit do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :submitted})
    end

    update :mark_succeeded do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :succeeded})
    end

    update :mark_failed do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :failed})
    end

    update :cancel do
      require_atomic?(false)
      accept([])
      change({Store.Support.Governance.TransitionState, target: :cancelled})
    end
  end

  postgres do
    table("payment_intents")
    repo(Store.Repo)

    custom_indexes do
      index([:state], name: "payment_intents_state_index")
      index([:order_id], name: "payment_intents_order_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:submit) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_succeeded) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:mark_failed) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:cancel) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
