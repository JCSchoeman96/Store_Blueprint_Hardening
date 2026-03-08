defmodule Store.Subscriptions.Subscription do
  @moduledoc """
  Customer subscription instance with replay-safe activation and renewal metadata.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, Store.Subscriptions.Types.SubscriptionStatus do
      allow_nil?(false)
      default(:pending)
      public?(true)
    end

    attribute :provider, Store.Payments.Types.Provider do
      allow_nil?(false)
      public?(true)
    end

    attribute :provider_subscription_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :billing_mode, Store.Subscriptions.Types.BillingMode do
      allow_nil?(false)
      public?(true)
    end

    attribute :billing_status_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :cancel_at_period_end, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :current_period_start_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :current_period_end_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :next_renewal_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :past_due_since_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :canceled_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :ended_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :canceled_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_customer_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :provider_billing_ref, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    attribute :renewal_amount_minor, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :renewal_currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :membership_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pending_renewal_amount_minor, :integer do
      allow_nil?(true)
      constraints(min: 0)
      public?(true)
    end

    attribute :pending_renewal_currency, :string do
      allow_nil?(true)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :change_effective_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :dunning_attempt_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :next_retry_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :retry_suppressed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :source_order_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_order_line_item_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :subscription_plan, Store.Subscriptions.SubscriptionPlan do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :pending_subscription_plan, Store.Subscriptions.SubscriptionPlan do
      source_attribute(:pending_subscription_plan_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :pending_variant, Store.Catalog.Variant do
      source_attribute(:pending_variant_id)
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :stored_payment_method, Store.Subscriptions.StoredPaymentMethod do
      allow_nil?(true)
      attribute_writable?(true)
      public?(true)
    end

    has_many :items, Store.Subscriptions.SubscriptionItem do
      destination_attribute(:subscription_id)
      public?(true)
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:activate_now, from: [:pending, :past_due], to: :active)
      transition(:mark_past_due_transition, from: :active, to: :past_due)
      transition(:cancel_now_transition, from: [:pending, :active, :past_due], to: :canceled)
      transition(:mark_expired_transition, from: [:active, :past_due], to: :expired)
      transition(:extend_period, from: :past_due, to: :active)
      transition(:extend_period, from: :active, to: :active)
    end
  end

  identities do
    identity(:unique_source_order_line_item, [:source_order_line_item_id])
    identity(:unique_provider_subscription_ref, [:provider, :provider_subscription_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_user do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 100)
      filter(expr(user_id == ^actor(:id)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_user do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id) and user_id == ^actor(:id)))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 50, max_page_size: 200)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :read_due_for_system do
      argument :now, :utc_datetime_usec do
        allow_nil?(false)
      end

      argument :limit, :integer do
        allow_nil?(false)
        default(100)
        constraints(min: 1, max: 500)
      end

      filter(
        expr(
          ((status == :active and not is_nil(next_renewal_at) and next_renewal_at <= ^arg(:now)) or
             (status == :past_due and is_nil(retry_suppressed_at) and
                (is_nil(next_retry_at) or next_retry_at <= ^arg(:now)))) and
            cancel_at_period_end == false
        )
      )

      prepare(build(sort: [next_renewal_at: :asc, id: :asc], limit: arg(:limit)))
    end

    create :create_from_order_line do
      accept([
        :user_id,
        :subscription_plan_id,
        :status,
        :provider,
        :provider_subscription_id,
        :billing_mode,
        :billing_status_reason,
        :cancel_at_period_end,
        :started_at,
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :provider_customer_ref,
        :provider_billing_ref,
        :variant_id,
        :quantity,
        :renewal_amount_minor,
        :renewal_currency,
        :membership_key,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at,
        :stored_payment_method_id,
        :source_order_id,
        :source_order_line_item_id
      ])

      upsert?(true)
      upsert_identity(:unique_source_order_line_item)
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    update :activate_now do
      require_atomic?(false)

      accept([
        :started_at,
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(
        {Store.Support.Governance.TransitionState,
         target: :active, state_attribute: :status, lock_attribute: nil}
      )

      change(set_attribute(:past_due_since_at, nil))
      change(set_attribute(:billing_status_reason, nil))
      change(set_attribute(:dunning_attempt_count, 0))
      change(set_attribute(:next_retry_at, nil))
      change(set_attribute(:retry_suppressed_at, nil))
    end

    update :mark_past_due_transition do
      require_atomic?(false)

      accept([
        :billing_status_reason,
        :past_due_since_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(fn changeset, _context ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :past_due_since_at)) do
          Ash.Changeset.change_attribute(
            changeset,
            :past_due_since_at,
            DateTime.utc_now() |> DateTime.truncate(:microsecond)
          )
        else
          changeset
        end
      end)

      change(
        {Store.Support.Governance.TransitionState,
         target: :past_due, state_attribute: :status, lock_attribute: nil}
      )
    end

    update :cancel_at_period_end_transition do
      require_atomic?(false)
      accept([])
      change(set_attribute(:cancel_at_period_end, true))
    end

    update :cancel_now_transition do
      require_atomic?(false)
      accept([:canceled_reason])

      change(
        {Store.Support.Governance.TransitionState,
         target: :canceled, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        changeset
        |> Ash.Changeset.change_attribute(:cancel_at_period_end, false)
        |> Ash.Changeset.change_attribute(:canceled_at, now)
        |> Ash.Changeset.change_attribute(:ended_at, now)
        |> Ash.Changeset.change_attribute(:next_renewal_at, nil)
        |> Ash.Changeset.change_attribute(:next_retry_at, nil)
        |> Ash.Changeset.change_attribute(:retry_suppressed_at, nil)
      end)
    end

    update :extend_period do
      require_atomic?(false)

      accept([
        :current_period_start_at,
        :current_period_end_at,
        :next_renewal_at,
        :subscription_plan_id,
        :variant_id,
        :renewal_amount_minor,
        :renewal_currency,
        :membership_key,
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at,
        :dunning_attempt_count,
        :next_retry_at,
        :retry_suppressed_at
      ])

      change(
        {Store.Support.Governance.TransitionState,
         target: :active, state_attribute: :status, lock_attribute: nil}
      )

      change(set_attribute(:past_due_since_at, nil))
      change(set_attribute(:billing_status_reason, nil))
      change(set_attribute(:dunning_attempt_count, 0))
      change(set_attribute(:next_retry_at, nil))
      change(set_attribute(:retry_suppressed_at, nil))
    end

    update :queue_change do
      require_atomic?(false)

      accept([
        :pending_variant_id,
        :pending_subscription_plan_id,
        :pending_renewal_amount_minor,
        :pending_renewal_currency,
        :change_effective_at,
        :next_retry_at,
        :retry_suppressed_at
      ])
    end

    update :mark_expired_transition do
      require_atomic?(false)
      accept([:canceled_reason])

      change(
        {Store.Support.Governance.TransitionState,
         target: :expired, state_attribute: :status, lock_attribute: nil}
      )

      change(fn changeset, _context ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        changeset
        |> Ash.Changeset.change_attribute(:ended_at, now)
        |> Ash.Changeset.change_attribute(:next_renewal_at, nil)
        |> Ash.Changeset.change_attribute(:next_retry_at, nil)
        |> Ash.Changeset.change_attribute(:retry_suppressed_at, nil)
      end)
    end

    update :set_provider_billing_reference do
      require_atomic?(false)

      accept([
        :provider_customer_ref,
        :provider_billing_ref,
        :stored_payment_method_id,
        :billing_status_reason,
        :next_retry_at,
        :retry_suppressed_at
      ])
    end
  end

  code_interface do
    define(:list_for_user, action: :read_for_user)
    define(:get_for_user, action: :get_for_user, args: [:id])
    define(:list_for_admin, action: :read_for_admin)
    define(:get_for_admin, action: :get_for_admin, args: [:id])
    define(:list_due_for_system, action: :read_due_for_system, args: [:now, :limit])
  end

  postgres do
    table("subscriptions")
    repo(Store.Repo)

    custom_indexes do
      index([:user_id, :status], name: "subscriptions_user_id_status_index")
      index([:status, :next_renewal_at], name: "subscriptions_status_next_renewal_at_index")
      index([:status, :next_retry_at], name: "subscriptions_status_next_retry_at_index")
      index([:provider, :provider_subscription_id], name: "subscriptions_provider_ref_index")
      index([:source_order_line_item_id], name: "subscriptions_source_order_line_item_id_index")
      index([:subscription_plan_id], name: "subscriptions_subscription_plan_id_index")
      index([:variant_id], name: "subscriptions_variant_id_index")
      index([:pending_subscription_plan_id], name: "subscriptions_pending_plan_id_index")
      index([:pending_variant_id], name: "subscriptions_pending_variant_id_index")
      index([:user_id, :membership_key], name: "subscriptions_user_membership_key_index")
      index([:stored_payment_method_id], name: "subscriptions_stored_payment_method_id_index")
    end
  end

  policies do
    bypass action([:read, :read_for_admin, :get_for_admin, :read_due_for_system]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:read_for_user, :get_for_user]) do
      access_type(:runtime)
      authorize_if(always())
    end

    policy action([:cancel_at_period_end_transition, :cancel_now_transition]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action([:queue_change]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action_type(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action([
             :activate_now,
             :mark_past_due_transition,
             :extend_period,
             :mark_expired_transition,
             :set_provider_billing_reference
           ]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
