defmodule StoreWeb.Admin.ShippingZones.IndexLive do
  @moduledoc """
  Admin CRUD surface for shipping zones using Ash-backed list reads and forms.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Pricing
  alias StoreWeb.Admin.ShippingZones.FormComponent
  alias StoreWeb.Params.Admin.ShippingZonesParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_shipping_zone, nil)
       |> stream(:shipping_zones, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- ShippingZonesParams.index_query(params),
         {:ok, shipping_zones} <- Pricing.list_shipping_zones_for_admin(query, actor),
         {:ok, selected_shipping_zone} <- load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_shipping_zone, selected_shipping_zone)
       |> stream(:shipping_zones, shipping_zones, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load shipping zones")
         |> assign(:selected_shipping_zone, nil)
         |> stream(:shipping_zones, [], reset: true)}
    end
  end

  @impl true
  def handle_info({:shipping_zone_saved, _shipping_zone}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Shipping zone saved")
     |> push_patch(to: ~p"/admin/shipping-zones")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-shipping-zones"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Shipping Zones</h1>
            <p class="text-sm text-base-content/70">
              Deterministic destination zones used by shipping-rate eligibility.
            </p>
          </div>
          <.button id="new-shipping-zone" patch={~p"/admin/shipping-zones/new"}>New Zone</.button>
        </div>

        <.table
          id="shipping-zones"
          rows={@streams.shipping_zones}
          row_id={fn {id, _shipping_zone} -> id end}
          row_item={fn {_id, shipping_zone} -> shipping_zone end}
        >
          <:col :let={shipping_zone} label="Code">{shipping_zone.code}</:col>
          <:col :let={shipping_zone} label="Country">{shipping_zone.country_code}</:col>
          <:col :let={shipping_zone} label="Region">{shipping_zone.region_code || "ALL"}</:col>
          <:col :let={shipping_zone} label="Active">
            {if(shipping_zone.active, do: "Yes", else: "No")}
          </:col>
          <:action :let={shipping_zone}>
            <.link patch={~p"/admin/shipping-zones/#{shipping_zone.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="shipping-zone-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={shipping_zone_form_id(@live_action, @selected_shipping_zone)}
            action={@live_action}
            current_user={@current_user}
            step_up_at_mono_usec={@step_up_at_mono_usec}
            shipping_zone={@selected_shipping_zone}
            patch={~p"/admin/shipping-zones"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case Pricing.get_shipping_zone_for_admin(id, actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, shipping_zone} -> {:ok, shipping_zone}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp shipping_zone_form_id(:new, _shipping_zone), do: "shipping-zone-form-new"
  defp shipping_zone_form_id(:edit, %{id: id}), do: "shipping-zone-form-#{id}"
  defp shipping_zone_form_id(:edit, _shipping_zone), do: "shipping-zone-form-edit"
  defp shipping_zone_form_id(_action, _shipping_zone), do: "shipping-zone-form"
end
