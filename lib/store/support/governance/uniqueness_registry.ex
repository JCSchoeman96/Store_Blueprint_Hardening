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
    %{key: :orders_checkout_key, table: "orders", columns: ["checkout_key"], mode: :active_now},
    %{
      key: :inventory_items_variant_id,
      table: "inventory_items",
      columns: ["variant_id"],
      mode: :active_now
    },
    %{
      key: :inventory_reservations_order_variant,
      table: "inventory_reservations",
      columns: ["order_id", "variant_id"],
      mode: :active_now
    },
    %{
      key: :inventory_reservations_reservation_key,
      table: "inventory_reservations",
      columns: ["reservation_key"],
      mode: :active_now
    },
    %{
      key: :webhook_receipts_idempotency_key,
      table: "webhook_receipts",
      columns: ["idempotency_key"],
      mode: :active_now
    },
    %{
      key: :payment_intents_payment_intent_key,
      table: "payment_intents",
      columns: ["payment_intent_key"],
      mode: :active_now
    },
    %{
      key: :payment_intents_in_flight_order_id,
      table: "payment_intents",
      columns: ["order_id"],
      mode: :active_now
    },
    %{
      key: :provider_events_provider_provider_event_id,
      table: "provider_events",
      columns: ["provider", "provider_event_id"],
      mode: :active_now
    },
    %{
      key: :payment_attempts_provider_event_key,
      table: "payment_attempts",
      columns: ["provider_event_key"],
      mode: :active_now
    },
    %{
      key: :payment_attempts_attempt_key,
      table: "payment_attempts",
      columns: ["attempt_key"],
      mode: :active_now
    },
    %{
      key: :payment_applications_application_key,
      table: "payment_applications",
      columns: ["application_key"],
      mode: :active_now
    },
    %{
      key: :refunds_idempotency_key,
      table: "refunds",
      columns: ["idempotency_key"],
      mode: :active_now
    },
    %{
      key: :refunds_provider_provider_refund_id,
      table: "refunds",
      columns: ["provider", "provider_refund_id"],
      mode: :active_now
    },
    %{
      key: :refund_attempts_refund_sequence_no,
      table: "refund_attempts",
      columns: ["refund_id", "sequence_no"],
      mode: :active_now
    },
    %{
      key: :refund_attempts_provider_event_key,
      table: "refund_attempts",
      columns: ["provider_event_key"],
      mode: :active_now
    },
    %{
      key: :refund_adjustments_refund_id,
      table: "refund_adjustments",
      columns: ["refund_id"],
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
