defmodule Store.Shipping.Facade do
  @moduledoc """
  Consumer and system scoped surfaces for shipping administration and quote lookup.
  """

  alias Store.Shipping
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.QuoteCache

  alias Store.Shipping.Queries.{
    AdminShippingMethodsQuery,
    AdminShippingRateRulesQuery,
    AdminShippingZonesQuery
  }

  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Support.Errors.{Error, Normalize}

  @spec list_shipping_zones_for_admin(map(), AdminShippingZonesQuery.t()) ::
          {:ok, [ShippingZone.t()]} | {:error, term()}
  def list_shipping_zones_for_admin(actor, %AdminShippingZonesQuery{} = query)
      when is_map(actor) do
    case Shipping.list_shipping_zones_for_admin(query, actor) do
      {:ok, zones} -> {:ok, zones}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_zone_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingZone.t() | nil} | {:error, term()}
  def get_shipping_zone_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Shipping.get_shipping_zone_for_admin(id, actor) do
      {:ok, zone} -> {:ok, zone}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec create_shipping_zone_for_admin(map(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def create_shipping_zone_for_admin(actor, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    ShippingZone
    |> Ash.Changeset.for_create(:create, attrs, context: context)
    |> Ash.create(domain: Shipping, actor: actor, context: context)
    |> normalize_result()
    |> maybe_invalidate_quote_cache()
  end

  @spec update_shipping_zone_for_admin(map(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ShippingZone.t()} | {:error, term()}
  def update_shipping_zone_for_admin(actor, id, attrs, opts)
      when is_map(actor) and is_binary(id) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    case Shipping.get_shipping_zone_for_admin(id, actor) do
      {:ok, %ShippingZone{} = shipping_zone} ->
        shipping_zone
        |> Ash.Changeset.for_update(:update, attrs, context: context)
        |> Ash.update(domain: Shipping, actor: actor, context: context)
        |> normalize_result()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "Shipping zone not found")}

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec list_shipping_methods_for_admin(map(), AdminShippingMethodsQuery.t()) ::
          {:ok, [ShippingMethod.t()]} | {:error, term()}
  def list_shipping_methods_for_admin(actor, %AdminShippingMethodsQuery{} = query)
      when is_map(actor) do
    case Shipping.list_shipping_methods_for_admin(query, actor) do
      {:ok, methods} -> {:ok, methods}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_method_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingMethod.t() | nil} | {:error, term()}
  def get_shipping_method_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Shipping.get_shipping_method_for_admin(id, actor) do
      {:ok, method} -> {:ok, method}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec create_shipping_method_for_admin(map(), map(), keyword()) ::
          {:ok, ShippingMethod.t()} | {:error, term()}
  def create_shipping_method_for_admin(actor, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    ShippingMethod
    |> Ash.Changeset.for_create(:create, attrs, context: context)
    |> Ash.create(domain: Shipping, actor: actor, context: context)
    |> normalize_result()
  end

  @spec update_shipping_method_for_admin(map(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ShippingMethod.t()} | {:error, term()}
  def update_shipping_method_for_admin(actor, id, attrs, opts)
      when is_map(actor) and is_binary(id) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    case Shipping.get_shipping_method_for_admin(id, actor) do
      {:ok, %ShippingMethod{} = method} ->
        method
        |> Ash.Changeset.for_update(:update, attrs, context: context)
        |> Ash.update(domain: Shipping, actor: actor, context: context)
        |> normalize_result()
        |> maybe_invalidate_quote_cache()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "Shipping method not found")}

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec list_shipping_rate_rules_for_admin(map(), AdminShippingRateRulesQuery.t()) ::
          {:ok, [ShippingRateRule.t()]} | {:error, term()}
  def list_shipping_rate_rules_for_admin(actor, %AdminShippingRateRulesQuery{} = query)
      when is_map(actor) do
    case Shipping.list_shipping_rate_rules_for_admin(query, actor) do
      {:ok, rules} -> {:ok, rules}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_shipping_rate_rule_for_admin(map(), Ecto.UUID.t()) ::
          {:ok, ShippingRateRule.t() | nil} | {:error, term()}
  def get_shipping_rate_rule_for_admin(actor, id) when is_map(actor) and is_binary(id) do
    case Shipping.get_shipping_rate_rule_for_admin(id, actor) do
      {:ok, rule} -> {:ok, rule}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec create_shipping_rate_rule_for_admin(map(), map(), keyword()) ::
          {:ok, ShippingRateRule.t()} | {:error, term()}
  def create_shipping_rate_rule_for_admin(actor, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    ShippingRateRule
    |> Ash.Changeset.for_create(:create, attrs, context: context)
    |> Ash.create(domain: Shipping, actor: actor, context: context)
    |> normalize_result()
    |> maybe_invalidate_quote_cache()
  end

  @spec update_shipping_rate_rule_for_admin(map(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ShippingRateRule.t()} | {:error, term()}
  def update_shipping_rate_rule_for_admin(actor, id, attrs, opts)
      when is_map(actor) and is_binary(id) and is_map(attrs) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    case Shipping.get_shipping_rate_rule_for_admin(id, actor) do
      {:ok, %ShippingRateRule{} = rule} ->
        rule
        |> Ash.Changeset.for_update(:update, attrs, context: context)
        |> Ash.update(domain: Shipping, actor: actor, context: context)
        |> normalize_result()
        |> maybe_invalidate_quote_cache()

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "Shipping rate rule not found")}

      {:error, error} ->
        {:error, Normalize.normalize(error)}
    end
  end

  @spec quote_options_for_system(QuoteRequest.t(), keyword()) ::
          {:ok, [Store.Shipping.Types.QuoteOption.t()]} | {:error, term()}
  def quote_options_for_system(%QuoteRequest{} = request, opts \\ []) when is_list(opts) do
    case Shipping.quote_options(request, opts) do
      {:ok, options} -> {:ok, options}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp maybe_invalidate_quote_cache({:ok, result}) do
    _ = QuoteCache.invalidate_all("shipping_mutation")
    {:ok, result}
  end

  defp maybe_invalidate_quote_cache({:error, _} = error), do: error
end
