defmodule StoreWeb.ShopLive.Index do
  @moduledoc """
  Public storefront listing for published catalog products.
  """

  use StoreWeb, :live_view

  alias Store.Catalog.Facade, as: CatalogFacade
  alias StoreWeb.Params.Catalog.ProductIndexParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, nil)
     |> assign(:products, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns[:current_user]

    with {:ok, query} <- ProductIndexParams.index_query(params),
         {:ok, products} <- CatalogFacade.list_products_for_public(actor, query) do
      {:noreply, assign(socket, query: query, products: products)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load products")
         |> assign(:products, [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="shop-index" class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Shop</h1>
          <p class="text-sm text-base-content/70">Published products for immediate purchase flow.</p>
        </header>

        <div
          :if={@products == []}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          No published products are available.
        </div>

        <div :if={@products != []} class="grid gap-4 sm:grid-cols-2">
          <article
            :for={product <- @products}
            class="rounded-xl border border-base-300 bg-base-200/50 p-4 transition hover:border-base-content/40"
          >
            <p class="text-xs uppercase tracking-wide text-base-content/60">{product.slug}</p>
            <h2 class="mt-2 text-lg font-medium">{product.title}</h2>
            <p :if={product.subtitle} class="mt-1 text-sm text-base-content/70">{product.subtitle}</p>
            <p class="mt-3 text-sm font-semibold">
              {format_money(product.default_variant && product.default_variant.price_minor)}
            </p>

            <.link
              navigate={~p"/shop/#{product.slug}"}
              class="mt-4 inline-flex rounded-lg border border-base-content/30 px-3 py-2 text-sm font-medium hover:bg-base-300"
            >
              View Product
            </.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp format_money(nil), do: "Price unavailable"

  defp format_money(minor) when is_integer(minor),
    do: "$#{:erlang.float_to_binary(minor / 100, decimals: 2)}"
end
