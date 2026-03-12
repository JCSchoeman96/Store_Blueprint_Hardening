defmodule StoreWeb.ShopLive.Index do
  @moduledoc """
  Public storefront listing for published catalog products.
  """

  use StoreWeb, :live_view

  alias Store.Catalog.Facade, as: CatalogFacade
  alias Store.Catalog.Queries.ShopQuery
  alias Store.Support.Telemetry.RepoStats
  alias StoreWeb.Live.StaticToLive
  alias StoreWeb.Params.Catalog.ShopQueryParams

  @mount_event [:store, :shop_live, :index, :mount]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, nil)
     |> assign(:hydrating?, true)
     |> assign(:warm_load_ref, nil)
     |> assign(:product_count, 0)
     |> stream(:products, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    started_at = System.monotonic_time()

    case ShopQueryParams.query(params) do
      {:ok, query} ->
        socket = assign(socket, :query, query)

        if connected?(socket) do
          ref = make_ref()

          {socket, jitter_ms} =
            StaticToLive.schedule_warm_load(
              assign(socket, :warm_load_ref, ref),
              {:load_warm_products, query, ref, started_at},
              jitter?: true,
              key: query
            )

          {:noreply, assign(socket, :warm_load_jitter_ms, jitter_ms)}
        else
          StaticToLive.emit_mount_telemetry(
            @mount_event,
            started_at,
            %{jitter_delay_ms: 0},
            %{phase: :static, result: :ok}
          )

          {:noreply, socket}
        end

      _ ->
        StaticToLive.emit_mount_telemetry(
          @mount_event,
          started_at,
          %{jitter_delay_ms: 0},
          %{phase: :static, result: :error}
        )

        {:noreply,
         socket
         |> put_flash(:error, "Unable to load products")
         |> assign(:hydrating?, false)
         |> assign(:product_count, 0)
         |> stream(:products, [], reset: true)}
    end
  end

  @impl true
  def handle_info(
        {:load_warm_products, query, ref, started_at},
        %{assigns: %{warm_load_ref: ref}} = socket
      ) do
    actor = socket.assigns[:current_user]

    {{socket, result}, repo_stats} =
      RepoStats.capture(fn ->
        case query
             |> ShopQuery.to_product_index_query()
             |> then(&CatalogFacade.list_product_cards_for_public(actor, &1)) do
          {:ok, products} ->
            {socket
             |> assign(:hydrating?, false)
             |> assign(:product_count, length(products))
             |> stream(:products, products, reset: true), :ok}

          {:error, _reason} ->
            {socket
             |> put_flash(:error, "Unable to load products")
             |> assign(:hydrating?, false)
             |> assign(:product_count, 0)
             |> stream(:products, [], reset: true), :error}
        end
      end)

    StaticToLive.emit_mount_telemetry(
      @mount_event,
      started_at,
      Map.merge(repo_stats, %{jitter_delay_ms: Map.get(socket.assigns, :warm_load_jitter_ms, 0)}),
      %{phase: :live, result: result}
    )

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
          :if={@hydrating?}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          Loading published products...
        </div>

        <div
          :if={!@hydrating? and @product_count == 0}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          No published products are available.
        </div>

        <div id="shop-products" phx-update="stream" class="grid gap-4 sm:grid-cols-2">
          <article
            :for={{dom_id, product} <- @streams.products}
            id={dom_id}
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
