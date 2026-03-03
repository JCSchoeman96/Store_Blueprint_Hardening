defmodule StoreWeb.Admin.ShippingMethods.IndexLive do
  @moduledoc """
  Admin CRUD surface for shipping methods.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Shipping.Facade, as: ShippingFacade
  alias StoreWeb.Admin.ShippingMethods.FormComponent
  alias StoreWeb.Params.Admin.ShippingMethodsParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_shipping_method, nil)
       |> stream(:shipping_methods, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- ShippingMethodsParams.index_query(extract_query_params(uri)),
         {:ok, shipping_methods} <- ShippingFacade.list_shipping_methods_for_admin(actor, query),
         {:ok, selected_shipping_method} <-
           load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_shipping_method, selected_shipping_method)
       |> stream(:shipping_methods, shipping_methods, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load shipping methods")
         |> assign(:selected_shipping_method, nil)
         |> stream(:shipping_methods, [], reset: true)}
    end
  end

  @impl true
  def handle_info({:shipping_method_saved, _shipping_method}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Shipping method saved")
     |> push_patch(to: ~p"/admin/shipping-methods")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-shipping-methods"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Shipping Methods</h1>
            <p class="text-sm text-base-content/70">
              Stable method codes used by checkout quote evidence and fulfillment.
            </p>
          </div>
          <.button id="new-shipping-method" patch={~p"/admin/shipping-methods/new"}>
            New Method
          </.button>
        </div>

        <.table
          id="shipping-methods"
          rows={@streams.shipping_methods}
          row_id={fn {id, _shipping_method} -> id end}
          row_item={fn {_id, shipping_method} -> shipping_method end}
        >
          <:col :let={shipping_method} label="Code">{shipping_method.code}</:col>
          <:col :let={shipping_method} label="Name">{shipping_method.name}</:col>
          <:col :let={shipping_method} label="Sort">{shipping_method.sort_order}</:col>
          <:col :let={shipping_method} label="Requires Address">
            {if(shipping_method.requires_address, do: "Yes", else: "No")}
          </:col>
          <:col :let={shipping_method} label="Active">
            {if(shipping_method.active, do: "Yes", else: "No")}
          </:col>
          <:action :let={shipping_method}>
            <.link patch={~p"/admin/shipping-methods/#{shipping_method.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="shipping-method-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={shipping_method_form_id(@live_action, @selected_shipping_method)}
            action={@live_action}
            current_user={@current_user}
            step_up_at_mono_usec={@step_up_at_mono_usec}
            shipping_method={@selected_shipping_method}
            patch={~p"/admin/shipping-methods"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case ShippingFacade.get_shipping_method_for_admin(actor, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, shipping_method} -> {:ok, shipping_method}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp shipping_method_form_id(:new, _shipping_method), do: "shipping-method-form-new"
  defp shipping_method_form_id(:edit, %{id: id}), do: "shipping-method-form-#{id}"
  defp shipping_method_form_id(:edit, _shipping_method), do: "shipping-method-form-edit"
  defp shipping_method_form_id(_action, _shipping_method), do: "shipping-method-form"

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
