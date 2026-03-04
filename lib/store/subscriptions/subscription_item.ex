defmodule Store.Subscriptions.SubscriptionItem do
  @moduledoc """
  Immutable subscription item snapshot derived from paid order evidence.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :quantity, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    attribute :plan_key_snapshot, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :amount_minor_snapshot, :integer do
      allow_nil?(false)
      constraints(min: 0)
      public?(true)
    end

    attribute :currency_snapshot, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(true)
    end

    attribute :interval_unit_snapshot, Store.Subscriptions.Types.IntervalUnit do
      allow_nil?(false)
      public?(true)
    end

    attribute :interval_count_snapshot, :integer do
      allow_nil?(false)
      constraints(min: 1)
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
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :variant, Store.Catalog.Variant do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_source_order_line_item, [:source_order_line_item_id])
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
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :create_from_order_line do
      accept([
        :subscription_id,
        :variant_id,
        :quantity,
        :plan_key_snapshot,
        :amount_minor_snapshot,
        :currency_snapshot,
        :interval_unit_snapshot,
        :interval_count_snapshot,
        :source_order_line_item_id
      ])

      upsert?(true)
      upsert_identity(:unique_source_order_line_item)
      upsert_fields([])
      return_skipped_upsert?(true)
    end
  end

  code_interface do
    define(:list_for_subscription, action: :read_for_subscription, args: [:subscription_id])
  end

  postgres do
    table("subscription_items")
    repo(Store.Repo)

    custom_indexes do
      index([:subscription_id], name: "subscription_items_subscription_id_index")
      index([:variant_id], name: "subscription_items_variant_id_index")
      index([:source_order_line_item_id], name: "subscription_items_source_line_item_id_index")
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action(:create_from_order_line) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end
end
