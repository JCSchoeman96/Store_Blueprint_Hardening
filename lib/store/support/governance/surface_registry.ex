defmodule Store.Support.Governance.SurfaceRegistry do
  @moduledoc """
  Authoritative registry of allowed public facade surfaces for governance checks.
  """

  @consumer_suffix_pattern ~r/_for_(user|admin|support|system)$/

  @registry %{
    Store.Orders.Facade => [
      {:list_orders_for_user, 2},
      {:list_orders_for_admin, 2},
      {:get_order_for_user, 2},
      {:get_order_for_admin, 2}
    ],
    Store.Payments.Facade => [
      {:list_payment_intents_for_admin, 2},
      {:get_payment_intent_for_admin, 2},
      {:ingest_webhook_receipt_for_system, 1},
      {:get_webhook_receipt_for_system, 1},
      {:process_payment_webhook_receipt_for_system, 1},
      {:process_refund_webhook_receipt_for_system, 1}
    ],
    Store.Pricing.Facade => [
      {:list_shipping_zones_for_admin, 2},
      {:get_shipping_zone_for_admin, 2},
      {:create_shipping_zone_for_admin, 3},
      {:update_shipping_zone_for_admin, 4},
      {:list_shipping_rates_for_admin, 2},
      {:get_shipping_rate_for_admin, 2},
      {:list_tax_rates_for_admin, 2},
      {:get_tax_rate_for_admin, 2}
    ]
  }

  @type facade_export :: {atom(), arity()}

  @spec registry() :: %{module() => [facade_export()]}
  def registry, do: @registry

  @spec allowed_exports(module()) :: [facade_export()]
  def allowed_exports(module) when is_atom(module), do: Map.get(@registry, module, [])

  @spec facade_modules() :: [module()]
  def facade_modules, do: Map.keys(@registry)

  @spec consumer_surface?({atom(), arity()}) :: boolean()
  def consumer_surface?({name, _arity}) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.match?(@consumer_suffix_pattern)
  end
end
