defmodule StoreWeb.Admin.ProductDigitalLinks.IndexLive do
  @moduledoc """
  Admin CRUD surface for product/variant digital links.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Digital.Facade, as: DigitalFacade
  alias StoreWeb.Admin.ProductDigitalLinks.FormComponent
  alias StoreWeb.Params.Admin.ProductDigitalLinksParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_product_digital_link, nil)
       |> stream(:product_digital_links, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- ProductDigitalLinksParams.index_query(extract_query_params(uri)),
         {:ok, links} <- DigitalFacade.list_product_digital_links_for_admin(actor, query),
         {:ok, selected_link} <- load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_product_digital_link, selected_link)
       |> stream(:product_digital_links, links, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load product digital links")
         |> assign(:selected_product_digital_link, nil)
         |> stream(:product_digital_links, [], reset: true)}
    end
  end

  @impl true
  def handle_info({:product_digital_link_saved, _product_digital_link}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Product digital link saved")
     |> push_patch(to: ~p"/admin/product-digital-links")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-product-digital-links"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Product Digital Links</h1>
            <p class="text-sm text-base-content/70">
              Deterministic asset links for product and variant line-item grants.
            </p>
          </div>
          <.button id="new-product-digital-link" patch={~p"/admin/product-digital-links/new"}>
            New Link
          </.button>
        </div>

        <.table
          id="product-digital-links"
          rows={@streams.product_digital_links}
          row_id={fn {id, _product_digital_link} -> id end}
          row_item={fn {_id, product_digital_link} -> product_digital_link end}
        >
          <:col :let={link} label="Product ID">{link.product_id || "-"}</:col>
          <:col :let={link} label="Variant ID">{link.variant_id || "-"}</:col>
          <:col :let={link} label="Asset">{digital_asset_title(link)}</:col>
          <:col :let={link} label="Position">{link.position}</:col>
          <:col :let={link} label="Grant Expiry Days">{link.grant_expires_in_days || "-"}</:col>
          <:col :let={link} label="Grant Max Downloads">{link.grant_max_downloads || "-"}</:col>
          <:action :let={link}>
            <.link patch={~p"/admin/product-digital-links/#{link.id}/edit"} class="btn btn-xs">
              Edit
            </.link>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="product-digital-link-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={product_digital_link_form_id(@live_action, @selected_product_digital_link)}
            action={@live_action}
            current_user={@current_user}
            product_digital_link={@selected_product_digital_link}
            patch={~p"/admin/product-digital-links"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor) do
    case DigitalFacade.get_product_digital_link_for_admin(actor, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, product_digital_link} -> {:ok, product_digital_link}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp product_digital_link_form_id(:new, _product_digital_link),
    do: "product-digital-link-form-new"

  defp product_digital_link_form_id(:edit, %{id: id}), do: "product-digital-link-form-#{id}"

  defp product_digital_link_form_id(:edit, _product_digital_link),
    do: "product-digital-link-form-edit"

  defp product_digital_link_form_id(_action, _product_digital_link),
    do: "product-digital-link-form"

  defp digital_asset_title(%{digital_asset: %{title: title}}) when is_binary(title), do: title
  defp digital_asset_title(_link), do: "-"

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
