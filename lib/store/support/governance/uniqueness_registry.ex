defmodule Store.Support.Governance.UniquenessRegistry do
  @moduledoc """
  Governance manifest of required uniqueness constraints.

  This module is intended for drift tests and documentation alignment.
  It is not used for runtime business decisions.
  """

  @type constraint :: %{
          key: atom(),
          table: String.t(),
          columns: [String.t()],
          mode: :active_now | :deferred_table_aware
        }

  @active_now [
    %{key: :users_email, table: "users", columns: ["email"], mode: :active_now},
    %{key: :orders_order_ref, table: "orders", columns: ["order_ref"], mode: :active_now},
    %{
      key: :webhook_receipts_idempotency_key,
      table: "webhook_receipts",
      columns: ["idempotency_key"],
      mode: :active_now
    },
    %{
      key: :provider_events_provider_provider_event_id,
      table: "provider_events",
      columns: ["provider", "provider_event_id"],
      mode: :active_now
    }
  ]

  @deferred_table_aware [
    %{key: :products_slug, table: "products", columns: ["slug"], mode: :deferred_table_aware},
    %{key: :posts_slug, table: "posts", columns: ["slug"], mode: :deferred_table_aware},
    %{key: :variants_sku, table: "variants", columns: ["sku"], mode: :deferred_table_aware},
    %{key: :coupons_code, table: "coupons", columns: ["code"], mode: :deferred_table_aware},
    %{key: :promotions_code, table: "promotions", columns: ["code"], mode: :deferred_table_aware}
  ]

  @spec active_now() :: [constraint()]
  def active_now, do: @active_now

  @spec deferred_table_aware() :: [constraint()]
  def deferred_table_aware, do: @deferred_table_aware

  @spec all() :: [constraint()]
  def all, do: @active_now ++ @deferred_table_aware
end
