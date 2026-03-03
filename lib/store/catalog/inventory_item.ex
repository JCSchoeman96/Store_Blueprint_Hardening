defmodule Store.Catalog.InventoryItem do
  @moduledoc """
  Inventory counters per variant. Phase 19 does not enforce hold/reservation semantics.
  """

  import Ecto.Query

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Catalog

  alias Store.Catalog.{AvailabilityCache, StockFastPath, Variant}
  alias Store.Repo

  attributes do
    uuid_v7_primary_key(:id)

    attribute :variant_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :stock_on_hand, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :reserved_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
    end

    attribute :allow_oversell, :boolean do
      allow_nil?(false)
      default(false)
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
    belongs_to :variant, Store.Catalog.Variant do
      source_attribute(:variant_id)
      destination_attribute(:id)
      define_attribute?(false)
      public?(true)
      allow_nil?(false)
      attribute_writable?(false)
    end
  end

  identities do
    identity(:unique_variant_id, [:variant_id])
  end

  actions do
    defaults([:read])

    read :read_for_admin do
      prepare(fn query, _context ->
        Ash.Query.sort(query, inserted_at: :desc, id: :asc)
      end)
    end

    create :create do
      accept([:variant_id, :stock_on_hand, :reserved_count, :allow_oversell])
      change(&invalidate_after_action/2)
    end

    update :update_counts do
      require_atomic?(false)
      accept([:stock_on_hand, :reserved_count, :allow_oversell])
      change(&invalidate_after_action/2)
    end

    update :set_on_hand do
      require_atomic?(false)
      accept([:stock_on_hand, :allow_oversell])
      change(&invalidate_after_action/2)
    end

    update :adjust_on_hand do
      require_atomic?(false)
      accept([:allow_oversell])

      argument :delta, :integer do
        allow_nil?(false)
      end

      change(fn changeset, _context ->
        current = changeset.data.stock_on_hand || 0
        delta = Ash.Changeset.get_argument(changeset, :delta) || 0
        next_value = current + delta

        if next_value < 0 do
          Ash.Changeset.add_error(changeset, field: :stock_on_hand, message: "must be >= 0")
        else
          Ash.Changeset.change_attribute(changeset, :stock_on_hand, next_value)
        end
      end)

      change(&invalidate_after_action/2)
    end
  end

  postgres do
    table("inventory_items")
    repo(Store.Repo)

    custom_indexes do
      index([:allow_oversell], name: "inventory_items_allow_oversell_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action([:create, :update_counts, :set_on_hand, :adjust_on_hand]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end

    policy always() do
      forbid_if(always())
    end
  end

  defp invalidate_after_action(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, inventory_item ->
      _ = StockFastPath.invalidate_variant_ids([inventory_item.variant_id])

      product_id =
        Variant
        |> where([variant], variant.id == ^inventory_item.variant_id)
        |> select([variant], variant.product_id)
        |> Repo.one()

      if is_binary(product_id) do
        _ = AvailabilityCache.invalidate_product(product_id)
      end

      {:ok, inventory_item}
    end)
  end
end
