defmodule Store.Support.Governance.SurfaceRegistry do
  @moduledoc """
  Authoritative registry of allowed public facade surfaces for governance checks.
  """

  @consumer_suffix_pattern ~r/_for_(public|user|admin|support|system)$/

  @registry %{
    Store.Orders.Facade => %{
      allowed_consumers: [:user, :admin],
      exports: [
        {:list_orders_for_user, 2},
        {:list_orders_for_admin, 2},
        {:get_order_for_user, 2},
        {:get_order_for_admin, 2},
        {:get_order_detail_for_user, 2}
      ]
    },
    Store.Payments.Facade => %{
      allowed_consumers: [:admin, :system],
      exports: [
        {:list_payment_intents_for_admin, 2},
        {:get_payment_intent_for_admin, 2},
        {:ingest_webhook_receipt_for_system, 1},
        {:get_webhook_receipt_for_system, 1},
        {:process_payment_webhook_receipt_for_system, 1},
        {:process_refund_webhook_receipt_for_system, 1}
      ]
    },
    Store.Pricing.Facade => %{
      allowed_consumers: [:admin],
      exports: [
        {:list_shipping_zones_for_admin, 2},
        {:get_shipping_zone_for_admin, 2},
        {:create_shipping_zone_for_admin, 3},
        {:update_shipping_zone_for_admin, 4},
        {:list_shipping_rates_for_admin, 2},
        {:get_shipping_rate_for_admin, 2},
        {:list_tax_rates_for_admin, 2},
        {:get_tax_rate_for_admin, 2}
      ]
    },
    Store.Catalog.Facade => %{
      allowed_consumers: [:public, :admin],
      exports: [
        {:list_products_for_public, 2},
        {:get_product_for_public, 2},
        {:normalize_cart_line_for_public, 1},
        {:list_products_for_admin, 2},
        {:get_product_for_admin, 2},
        {:publish_product_for_admin, 2},
        {:unpublish_product_for_admin, 2},
        {:archive_product_for_admin, 2}
      ]
    },
    Store.Carts.Facade => %{
      allowed_consumers: [:user],
      exports: [
        {:get_cart_for_user, 2},
        {:get_cart_view_for_user, 3},
        {:add_item_for_user, 3},
        {:update_item_qty_for_user, 3},
        {:remove_item_for_user, 3},
        {:merge_token_into_user_for_user, 2}
      ]
    },
    Store.Shipping.Facade => %{
      allowed_consumers: [:admin, :system],
      exports: [
        {:list_shipping_zones_for_admin, 2},
        {:get_shipping_zone_for_admin, 2},
        {:create_shipping_zone_for_admin, 3},
        {:update_shipping_zone_for_admin, 4},
        {:list_shipping_methods_for_admin, 2},
        {:get_shipping_method_for_admin, 2},
        {:create_shipping_method_for_admin, 3},
        {:update_shipping_method_for_admin, 4},
        {:list_shipping_rate_rules_for_admin, 2},
        {:get_shipping_rate_rule_for_admin, 2},
        {:create_shipping_rate_rule_for_admin, 3},
        {:update_shipping_rate_rule_for_admin, 4},
        {:quote_options_for_system, 1},
        {:quote_options_for_system, 2}
      ]
    },
    Store.Fulfillment.Facade => %{
      allowed_consumers: [:admin, :support, :system],
      exports: [
        {:list_fulfillment_orders_for_admin, 2},
        {:get_fulfillment_order_for_admin, 2},
        {:mark_packed_for_support, 2},
        {:mark_shipped_for_support, 3},
        {:mark_delivered_for_support, 2},
        {:cancel_fulfillment_for_admin, 2},
        {:cancel_fulfillment_for_admin, 3},
        {:ensure_paid_order_fulfillment_for_system, 1},
        {:enqueue_paid_order_fulfillment_for_system, 1},
        {:get_fulfillment_by_order_id_for_system, 1}
      ]
    },
    Store.Comms.Facade => %{
      allowed_consumers: [:admin],
      exports: [
        {:list_email_outboxes_for_admin, 2},
        {:get_email_outbox_for_admin, 2}
      ]
    }
  }

  @type facade_export :: {atom(), arity()}

  @spec registry() :: %{module() => [facade_export()]}
  def registry, do: @registry

  @spec allowed_exports(module()) :: [facade_export()]
  def allowed_exports(module) when is_atom(module) do
    @registry
    |> Map.get(module, %{exports: []})
    |> Map.get(:exports, [])
  end

  @spec allowed_consumers(module()) :: [atom()]
  def allowed_consumers(module) when is_atom(module) do
    @registry
    |> Map.get(module, %{allowed_consumers: []})
    |> Map.get(:allowed_consumers, [])
  end

  @spec facade_modules() :: [module()]
  def facade_modules, do: Map.keys(@registry)

  @spec consumer_surface?({atom(), arity()}) :: boolean()
  def consumer_surface?({name, _arity}) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.match?(@consumer_suffix_pattern)
  end

  @spec consumer_surface?(module(), {atom(), arity()}) :: boolean()
  def consumer_surface?(module, {name, _arity}) when is_atom(module) and is_atom(name) do
    case extract_consumer(name) do
      {:ok, consumer} -> consumer in allowed_consumers(module)
      :error -> false
    end
  end

  defp extract_consumer(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split("_for_")
    |> case do
      [_prefix, consumer] -> {:ok, String.to_atom(consumer)}
      _ -> :error
    end
  end
end
