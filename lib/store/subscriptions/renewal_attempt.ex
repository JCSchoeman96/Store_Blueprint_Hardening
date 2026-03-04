defmodule Store.Subscriptions.RenewalAttempt do
  @moduledoc """
  Idempotency anchor for one subscription renewal per billing period.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :period_start_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :period_end_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :renewal_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.RenewalAttemptStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :order_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :payment_intent_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_message, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :attempt_no, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_subscription_renewal_key, [:subscription_id, :renewal_key])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_subscription do
      argument :subscription_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(subscription_id == ^arg(:subscription_id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 100, max_page_size: 500)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    create :create_or_reuse do
      accept([
        :subscription_id,
        :period_start_at,
        :period_end_at,
        :renewal_key,
        :status,
        :order_id,
        :payment_intent_id,
        :failure_code,
        :failure_message,
        :attempt_no
      ])

      upsert?(true)
      upsert_identity(:unique_subscription_renewal_key)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :mark_succeeded do
      require_atomic?(false)
      accept([:order_id, :payment_intent_id])
      change(set_attribute(:status, :succeeded))
      change(set_attribute(:failure_code, nil))
      change(set_attribute(:failure_message, nil))
    end

    update :mark_processing do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :processing))
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:failure_code, :failure_message, :attempt_no])
      change(set_attribute(:status, :failed))
    end
  end

  code_interface do
    define(:list_for_subscription, action: :read_for_subscription, args: [:subscription_id])
    define(:list_for_admin, action: :read_for_admin)
  end

  postgres do
    table("renewal_attempts")
    repo(Store.Repo)

    custom_indexes do
      index([:subscription_id], name: "renewal_attempts_subscription_id_index")
      index([:inserted_at], name: "renewal_attempts_inserted_at_index")
      index([:status, :inserted_at], name: "renewal_attempts_status_inserted_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
