defmodule StoreWeb.Admin.Products.IndexLive do
  @moduledoc """
  Minimal admin catalog product CRUD and lifecycle transitions.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Catalog.Facade, as: CatalogFacade
  alias StoreWeb.Admin.Products.FormComponent
  alias StoreWeb.Params.Catalog.ProductAdminIndexParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin]) do
      {:ok,
       socket
       |> assign(:query, nil)
       |> assign(:selected_product, nil)
       |> stream(:products, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- ProductAdminIndexParams.index_query(params),
         {:ok, products} <- CatalogFacade.list_products_for_admin(actor, query),
         {:ok, selected_product} <- load_selected(socket.assigns.live_action, params, actor) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:selected_product, selected_product)
       |> stream(:products, products, reset: true)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load products")
         |> assign(:selected_product, nil)
         |> stream(:products, [], reset: true)}
    end
  end

  @impl true
  def handle_event("publish", %{"id" => id}, socket), do: transition(socket, :publish, id)
  def handle_event("unpublish", %{"id" => id}, socket), do: transition(socket, :unpublish, id)
  def handle_event("archive", %{"id" => id}, socket), do: transition(socket, :archive, id)

  @impl true
  def handle_info({:product_saved, _product}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Product saved")
     |> push_patch(to: ~p"/admin/products")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-products"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Products</h1>
            <p class="text-sm text-base-content/70">
              Simple product catalog with default variant identity.
            </p>
          </div>
          <.button id="new-product" patch={~p"/admin/products/new"}>New Product</.button>
        </div>

        <.table
          id="products"
          rows={@streams.products}
          row_id={fn {id, _product} -> id end}
          row_item={fn {_id, product} -> product end}
        >
          <:col :let={product} label="Slug">{product.slug}</:col>
          <:col :let={product} label="Title">{product.title}</:col>
          <:col :let={product} label="Status">{product.status}</:col>
          <:col :let={product} label="Price">
            {format_money(product.default_variant && product.default_variant.price_minor)}
          </:col>
          <:action :let={product}>
            <div class="flex flex-wrap gap-2">
              <.link patch={~p"/admin/products/#{product.id}/edit"} class="btn btn-xs">Edit</.link>
              <.link navigate={~p"/admin/products/#{product.id}/variants"} class="btn btn-xs">
                Variants
              </.link>
              <.button
                :if={product.status == :draft}
                id={"publish-#{product.id}"}
                phx-click="publish"
                phx-value-id={product.id}
                class="btn btn-xs"
              >
                Publish
              </.button>
              <.button
                :if={product.status == :published}
                id={"unpublish-#{product.id}"}
                phx-click="unpublish"
                phx-value-id={product.id}
                class="btn btn-xs"
              >
                Unpublish
              </.button>
              <.button
                :if={product.status != :archived}
                id={"archive-#{product.id}"}
                phx-click="archive"
                phx-value-id={product.id}
                class="btn btn-xs"
              >
                Archive
              </.button>
            </div>
          </:action>
        </.table>

        <section
          :if={@live_action in [:new, :edit]}
          id="product-form-panel"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <.live_component
            module={FormComponent}
            id={product_form_id(@live_action, @selected_product)}
            action={@live_action}
            current_user={@current_user}
            product={@selected_product}
            patch={~p"/admin/products"}
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_selected(:edit, %{"id" => id}, actor),
    do: CatalogFacade.get_product_for_admin(actor, id)

  defp load_selected(_live_action, _params, _actor), do: {:ok, nil}

  defp product_form_id(:new, _product), do: "product-form-new"
  defp product_form_id(:edit, %{id: id}), do: "product-form-#{id}"
  defp product_form_id(:edit, _product), do: "product-form-edit"
  defp product_form_id(_action, _product), do: "product-form"

  defp format_money(nil), do: "-"

  defp format_money(minor) when is_integer(minor),
    do: "$#{:erlang.float_to_binary(minor / 100, decimals: 2)}"

  defp transition(socket, transition, id) do
    actor = socket.assigns.current_user

    result =
      case transition do
        :publish -> CatalogFacade.publish_product_for_admin(actor, id)
        :unpublish -> CatalogFacade.unpublish_product_for_admin(actor, id)
        :archive -> CatalogFacade.archive_product_for_admin(actor, id)
      end

    case result do
      {:ok, _product} ->
        {:noreply,
         socket
         |> put_flash(:info, "Transition applied")
         |> push_patch(to: ~p"/admin/products")}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to apply transition")}
    end
  end
end
