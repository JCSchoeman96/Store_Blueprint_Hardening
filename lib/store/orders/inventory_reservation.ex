defmodule Store.Orders.InventoryReservation do
  @moduledoc """
  Reservation evidence and lifecycle for order+variant inventory holds.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Orders

  alias Store.Support.Governance.TransitionState

  @default_ttl_seconds 15 * 60

  attributes do
    uuid_v7_primary_key(:id)

    attribute :order_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :variant_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :reservation_key, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :state, Store.Orders.Types.InventoryReservationState do
      allow_nil?(false)
      default(:active)
      public?(true)
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil?(false)
      default(fn -> DateTime.add(DateTime.utc_now(), @default_ttl_seconds, :second) end)
      public?(true)
    end

    attribute :consumed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :expired_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :cancelled_at, :utc_datetime_usec do
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
    initial_states([:active])
    default_initial_state(:active)

    transitions do
      transition(:mark_consumed, from: :active, to: :consumed)
      transition(:mark_expired, from: :active, to: :expired)
      transition(:mark_cancelled, from: :active, to: :cancelled)
    end
  end

  identities do
    identity(:unique_order_variant, [:order_id, :variant_id])
    identity(:unique_reservation_key, [:reservation_key])
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :order_id,
        :variant_id,
        :reservation_key,
        :quantity,
        :state,
        :expires_at,
        :consumed_at,
        :expired_at,
        :cancelled_at
      ])

      change(fn changeset, _context ->
        reservation_key = Ash.Changeset.get_attribute(changeset, :reservation_key)
        order_id = Ash.Changeset.get_attribute(changeset, :order_id)
        variant_id = Ash.Changeset.get_attribute(changeset, :variant_id)

        case reservation_key do
          key when is_binary(key) ->
            changeset

          _ ->
            Ash.Changeset.change_attribute(
              changeset,
              :reservation_key,
              "order:#{order_id}:sku:#{variant_id}"
            )
        end
      end)
    end

    update :set_quantity do
      accept([:quantity, :expires_at])
    end

    update :mark_consumed do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :consumed_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :consumed_at, DateTime.utc_now())
          _value -> changeset
        end
      end)

      change({TransitionState, target: :consumed})
    end

    update :mark_expired do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :expired_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :expired_at, DateTime.utc_now())
          _value -> changeset
        end
      end)

      change({TransitionState, target: :expired})
    end

    update :mark_cancelled do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :cancelled_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :cancelled_at, DateTime.utc_now())
          _value -> changeset
        end
      end)

      change({TransitionState, target: :cancelled})
    end
  end

  postgres do
    table("inventory_reservations")
    repo(Store.Repo)

    custom_indexes do
      index([:order_id, :state], name: "inventory_reservations_order_state_index")
      index([:variant_id, :state], name: "inventory_reservations_variant_state_index")
      index([:state, :expires_at], name: "inventory_reservations_state_expires_at_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:create, :set_quantity, :mark_consumed, :mark_expired, :mark_cancelled]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end
end
