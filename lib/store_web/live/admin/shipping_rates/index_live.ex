defmodule StoreWeb.Admin.ShippingRates.IndexLive do
  @moduledoc """
  Admin CRUD surface for shipping rates using Ash-backed list reads and forms.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Queries.{AdminShippingMethodsQuery, AdminShippingZonesQuery}
  alias StoreWeb.Admin.ShippingRates.FormComponent
  alias StoreWeb.Params.Admin.ShippingRatesParams

  @method_options_limit 100
  @zone_options_limit 100

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:zone_options, [])
       |> assign(:method_options, [])
       |> assign(:selected_shipping_rate, nil)
       |> stream(:shipping_rates, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- ShippingRatesParams.index_query(extract_query_params(uri)),
         {:ok, shipping_rates} <- ShippingFacade.list_shipping_rate_rules_for_admin(actor, query),
         {:ok, zone_options} <- load_zone_options(actor),
         {:ok, method_options} <- load_method_options(actor),
         {:ok, selected_shipping_rate} <- load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:zone_options, zone_options)
       |> assign(:method_options, method_options)
       |> assign(:selected_shipping_rate, selected_shipping_rate)
       |> stream(:shipping_rates, shipping_rates, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load shipping rates")
         |> assign(:selected_shipping_rate, nil)
         |> stream(:shipping_rates, [], reset: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    params =
      socket.assigns.query
      |> query_to_params()
      |> put_zone_filter(Map.get(params, "shipping_zone_id"))
      |> put_method_filter(Map.get(params, "shipping_method_id"))

    {:noreply, push_patch(socket, to: ~p"/admin/shipping-rates?#{params}")}
  end

  @impl true
  def handle_info({:shipping_rate_saved, _shipping_rate}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Shipping rate saved")
     |> push_patch(to: ~p"/admin/shipping-rates")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-shipping-rates"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Shipping Rates</h1>
            <p class="text-sm text-base-content/70">
              Destination and weight-aware rates used in deterministic shipping selection.
            </p>
          </div>
          <.button id="new-shipping-rate" patch={~p"/admin/shipping-rates/new"}>New Rate</.button>
        </div>

        <form id="shipping-rate-filter-form" phx-change="filter" class="grid gap-3 lg:grid-cols-2">
          <div>
            <label class="label mb-1 text-sm font-medium">Filter by Zone</label>
            <select name="shipping_zone_id" class="select w-full">
              <option value="">All Zones</option>
              <option
                :for={{label, value} <- @zone_options}
                value={value}
                selected={to_string(@query && @query.shipping_zone_id) == to_string(value)}
              >
                {label}
              </option>
            </select>
          </div>

          <div>
            <label class="label mb-1 text-sm font-medium">Filter by Method</label>
            <select name="shipping_method_id" class="select w-full">
              <option value="">All Methods</option>
              <option
                :for={{label, value} <- @method_options}
                value={value}
                selected={to_string(@query && @query.shipping_method_id) == to_string(value)}
              >
                {label}
              </option>
            </select>
          </div>
        </form>

        <.table
          id="shipping-rates"
          rows={@streams.shipping_rates}
          row_id={fn {id, _shipping_rate} -> id end}
          row_item={fn {_id, shipping_rate} -> shipping_rate end}
        >
          <:col :let={shipping_rate} label="Code">{shipping_rate.code}</:col>
          <:col :let={shipping_rate} label="Currency">{shipping_rate.currency}</:col>
          <:col :let={shipping_rate} label="Method">{shipping_rate.shipping_method_id}</:col>
          <:col :let={shipping_rate} label="Zone">{shipping_rate.shipping_zone_id || "GLOBAL"}</:col>
          <:col :let={shipping_rate} label="Cost">{shipping_rate.shipping_cost_minor}</:col>
          <:col :let={shipping_rate} label="Active">
            {if(shipping_rate.active, do: "Yes", else: "No")}
          </:col>
          <:action :let={shipping_rate}>
            <.link patch={~p"/admin/shipping-rates/#{shipping_rate.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="shipping-rate-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={shipping_rate_form_id(@live_action, @selected_shipping_rate)}
            action={@live_action}
            current_user={@current_user}
            step_up_at_mono_usec={@step_up_at_mono_usec}
            shipping_rate={@selected_shipping_rate}
            zone_options={@zone_options}
            method_options={@method_options}
            patch={~p"/admin/shipping-rates"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_zone_options(actor) do
    with {:ok, query} <- AdminShippingZonesQuery.new(%{"limit" => @zone_options_limit}),
         {:ok, zones} <- ShippingFacade.list_shipping_zones_for_admin(actor, query) do
      {:ok, Enum.map(zones, &{"#{&1.code} (#{&1.country_code})", &1.id})}
    end
  end

  defp load_method_options(actor) do
    with {:ok, query} <- AdminShippingMethodsQuery.new(%{"limit" => @method_options_limit}),
         {:ok, methods} <- ShippingFacade.list_shipping_methods_for_admin(actor, query) do
      {:ok, Enum.map(methods, &{"#{&1.name} (#{&1.code})", &1.id})}
    end
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case ShippingFacade.get_shipping_rate_rule_for_admin(actor, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, shipping_rate} -> {:ok, shipping_rate}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp query_to_params(nil), do: %{"limit" => "20"}

  defp query_to_params(query) do
    %{"limit" => to_string(query.limit)}
    |> put_zone_filter(query.shipping_zone_id)
    |> put_method_filter(query.shipping_method_id)
  end

  defp put_zone_filter(params, nil), do: Map.delete(params, "shipping_zone_id")
  defp put_zone_filter(params, ""), do: Map.delete(params, "shipping_zone_id")

  defp put_zone_filter(params, shipping_zone_id),
    do: Map.put(params, "shipping_zone_id", shipping_zone_id)

  defp put_method_filter(params, nil), do: Map.delete(params, "shipping_method_id")
  defp put_method_filter(params, ""), do: Map.delete(params, "shipping_method_id")

  defp put_method_filter(params, shipping_method_id),
    do: Map.put(params, "shipping_method_id", shipping_method_id)

  defp shipping_rate_form_id(:new, _shipping_rate), do: "shipping-rate-form-new"
  defp shipping_rate_form_id(:edit, %{id: id}), do: "shipping-rate-form-#{id}"
  defp shipping_rate_form_id(:edit, _shipping_rate), do: "shipping-rate-form-edit"
  defp shipping_rate_form_id(_action, _shipping_rate), do: "shipping-rate-form"

  defp extract_query_params(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:query)
    |> case do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp extract_query_params(_uri), do: %{}
end
