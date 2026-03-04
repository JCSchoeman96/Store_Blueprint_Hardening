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
    },
    %{
      key: :carts_active_token,
      table: "carts",
      columns: ["token"],
      mode: :active_now
    },
    %{
      key: :carts_active_user_id,
      table: "carts",
      columns: ["user_id"],
      mode: :active_now
    },
    %{
      key: :cart_items_cart_variant_no_plan,
      table: "cart_items",
      columns: ["cart_id", "variant_id"],
      mode: :active_now
    },
    %{
      key: :cart_items_cart_variant_plan,
      table: "cart_items",
      columns: ["cart_id", "variant_id", "subscription_plan_id"],
      mode: :active_now
    },
    %{
      key: :checkout_drafts_checkout_key,
      table: "checkout_drafts",
      columns: ["checkout_key"],
      mode: :active_now
    },
    %{
      key: :checkout_drafts_cart_id_cart_version,
      table: "checkout_drafts",
      columns: ["cart_id", "cart_version"],
      mode: :active_now
    },
    %{
      key: :checkout_drafts_order_id,
      table: "checkout_drafts",
      columns: ["order_id"],
      mode: :active_now
    },
    %{
      key: :payment_intents_provider_provider_payment_id,
      table: "payment_intents",
      columns: ["provider", "provider_payment_id"],
      mode: :active_now
    },
    %{
      key: :payment_intents_provider_provider_session_id,
      table: "payment_intents",
      columns: ["provider", "provider_session_id"],
      mode: :active_now
    },
    %{
      key: :webhook_receipts_provider_provider_event_id,
      table: "webhook_receipts",
      columns: ["provider", "provider_event_id"],
      mode: :active_now
    },
    %{
      key: :email_outboxes_idempotency_key,
      table: "email_outboxes",
      columns: ["idempotency_key"],
      mode: :active_now
    },
    %{
      key: :email_outboxes_order_id_template_kind,
      table: "email_outboxes",
      columns: ["order_id", "template_kind"],
      mode: :active_now
    },
    %{
      key: :email_outboxes_refund_id_template_kind,
      table: "email_outboxes",
      columns: ["refund_id", "template_kind"],
      mode: :active_now
    },
    %{
      key: :shipping_methods_code,
      table: "shipping_methods",
      columns: ["code"],
      mode: :active_now
    },
    %{
      key: :shipping_rates_code,
      table: "shipping_rates",
      columns: ["code"],
      mode: :active_now
    },
    %{
      key: :order_adjustments_shipping_order_id,
      table: "order_adjustments",
      columns: ["order_id"],
      mode: :active_now
    },
    %{
      key: :fulfillment_orders_order_id,
      table: "fulfillment_orders",
      columns: ["order_id"],
      mode: :active_now
    },
    %{
      key: :shipments_tracking_ref,
      table: "shipments",
      columns: ["tracking_ref"],
      mode: :active_now
    },
    %{
      key: :fulfillment_items_fulfillment_order_line_item,
      table: "fulfillment_items",
      columns: ["fulfillment_order_id", "order_line_item_id"],
      mode: :active_now
    },
    %{
      key: :digital_assets_key,
      table: "digital_assets",
      columns: ["key"],
      mode: :active_now
    },
    %{
      key: :product_digital_links_product_digital_asset,
      table: "product_digital_links",
      columns: ["product_id", "digital_asset_id"],
      mode: :active_now
    },
    %{
      key: :product_digital_links_variant_digital_asset,
      table: "product_digital_links",
      columns: ["variant_id", "digital_asset_id"],
      mode: :active_now
    },
    %{
      key: :download_grants_order_line_item_digital_asset,
      table: "download_grants",
      columns: ["order_line_item_id", "digital_asset_id"],
      mode: :active_now
    },
    %{
      key: :product_options_product_slug,
      table: "product_options",
      columns: ["product_id", "slug"],
      mode: :active_now
    },
    %{
      key: :product_option_values_option_slug,
      table: "product_option_values",
      columns: ["product_option_id", "slug"],
      mode: :active_now
    },
    %{
      key: :variant_option_selections_variant_option,
      table: "variant_option_selections",
      columns: ["variant_id", "product_option_id"],
      mode: :active_now
    },
    %{
      key: :variants_active_selection_signature,
      table: "variants",
      columns: ["product_id", "selection_signature"],
      mode: :active_now
    },
    %{
      key: :subscription_plans_key,
      table: "subscription_plans",
      columns: ["key"],
      mode: :active_now
    },
    %{
      key: :variant_subscription_plans_variant_subscription_plan,
      table: "variant_subscription_plans",
      columns: ["variant_id", "subscription_plan_id"],
      mode: :active_now
    },
    %{
      key: :variant_subscription_plans_active_variant,
      table: "variant_subscription_plans",
      columns: ["variant_id"],
      mode: :active_now
    },
    %{
      key: :stored_payment_methods_provider_customer_payment_method,
      table: "stored_payment_methods",
      columns: ["provider", "provider_customer_ref", "provider_payment_method_ref"],
      mode: :active_now
    },
    %{
      key: :subscriptions_source_order_line_item_id,
      table: "subscriptions",
      columns: ["source_order_line_item_id"],
      mode: :active_now
    },
    %{
      key: :subscriptions_provider_provider_subscription_id,
      table: "subscriptions",
      columns: ["provider", "provider_subscription_id"],
      mode: :active_now
    },
    %{
      key: :subscription_items_source_order_line_item_id,
      table: "subscription_items",
      columns: ["source_order_line_item_id"],
      mode: :active_now
    },
    %{
      key: :renewal_attempts_subscription_renewal_key,
      table: "renewal_attempts",
      columns: ["subscription_id", "renewal_key"],
      mode: :active_now
    },
    %{
      key: :entitlement_grants_user_scope_source,
      table: "entitlement_grants",
      columns: ["user_id", "kind", "scope_key", "source_kind", "source_id"],
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
