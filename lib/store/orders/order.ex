defmodule Store.Orders.Order do
  @moduledoc """
  Order lifecycle state machine with replay-safe transitions.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshJsonApi.Resource],
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

    attribute :checkout_key, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_rate_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_rate_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_cost_minor_original, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_cost_minor_effective, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :free_shipping_applied, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :free_shipping_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_tax_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :tax_total_minor, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :shipping_country_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_region_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :shipping_postal_code, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :tax_as_of, :utc_datetime_usec do
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
    identity(:unique_checkout_key, [:checkout_key])
  end

  actions do
    defaults([:read])

    read :read_for_user do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_user do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :read_for_admin do
      pagination(offset?: true, required?: false, default_limit: 20, max_page_size: 50)
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
    end

    read :get_for_admin do
      get?(true)

      argument :id, :uuid do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    create :create do
      accept([:order_ref, :user_id, :checkout_key])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :order_ref) do
          nil -> Ash.Changeset.change_attribute(changeset, :order_ref, OrderRef.generate())
          _order_ref -> changeset
        end
      end)
    end

    create :begin_checkout do
      accept([:order_ref, :user_id, :checkout_key])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :order_ref) do
          nil -> Ash.Changeset.change_attribute(changeset, :order_ref, OrderRef.generate())
          _order_ref -> changeset
        end
      end)

      upsert?(true)
      upsert_identity(:unique_checkout_key)
      upsert_fields([])
      return_skipped_upsert?(true)
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

    update :write_tax_shipping_snapshot do
      require_atomic?(false)

      accept([
        :shipping_rate_id,
        :shipping_rate_code,
        :shipping_cost_minor_original,
        :shipping_cost_minor_effective,
        :free_shipping_applied,
        :free_shipping_reason,
        :shipping_tax_minor,
        :tax_total_minor,
        :shipping_country_code,
        :shipping_region_code,
        :shipping_postal_code,
        :tax_as_of
      ])
    end
  end

  json_api do
    type("order")
    includes([])
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("orders")
    repo(Store.Repo)

    custom_indexes do
      index([:state], name: "orders_state_index")
      index([:order_ref], name: "orders_order_ref_index")
      index([:user_id], name: "orders_user_id_index")
      index([:shipping_rate_id], name: "orders_shipping_rate_id_index")
      index([:tax_as_of], name: "orders_tax_as_of_index")
    end
  end

  policies do
    bypass action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:read, :read_for_user, :get_for_user]) do
      authorize_if(expr(user_id == ^actor(:id)))
    end

    policy action(:create) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy action(:begin_checkout) do
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

    policy action(:write_tax_shipping_snapshot) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
