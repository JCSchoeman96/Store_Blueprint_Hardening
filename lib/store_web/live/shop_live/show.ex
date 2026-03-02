defmodule StoreWeb.ShopLive.Show do
  @moduledoc """
  Public storefront product detail by slug.
  """

  use StoreWeb, :live_view

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Catalog.Facade, as: CatalogFacade
  alias StoreWeb.Params.Carts.CartItemParams

  @impl true
  def mount(_params, session, socket) do
    cart_token = Map.get(session, "cart_token")

    {:ok,
     socket
     |> assign(:product, nil)
     |> assign(:cart_token, cart_token)
     |> assign(:form, to_form(%{"quantity" => "1"}, as: :cart_line))}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    actor = socket.assigns[:current_user]

    case CatalogFacade.get_product_for_public(actor, slug) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> put_flash(:error, "Product not found")
         |> push_navigate(to: ~p"/shop")}

      {:ok, product} ->
        {:noreply, assign(socket, :product, product)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load product")
         |> push_navigate(to: ~p"/shop")}
    end
  end

  @impl true
  def handle_event("queue_cart_line", %{"cart_line" => %{"quantity" => quantity}}, socket) do
    product = socket.assigns.product
    actor = socket.assigns[:current_user]

    params = %{
      "variant_id" => product.default_variant_id,
      "qty" => quantity
    }

    case CartItemParams.input(params) do
      {:ok, input} ->
        case CartsFacade.add_item_for_user(actor, socket.assigns.cart_token, input) do
          {:ok, _cart} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added to cart")
             |> push_navigate(to: ~p"/cart")}

          {:error, _error} ->
            {:noreply, put_flash(socket, :error, "Unable to add item to cart")}
        end

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Invalid cart line input")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section :if={@product} id="shop-show" class="space-y-6">
        <header class="space-y-2">
          <p class="text-xs uppercase tracking-wide text-base-content/60">{@product.slug}</p>
          <h1 class="text-2xl font-semibold">{@product.title}</h1>
          <p :if={@product.subtitle} class="text-sm text-base-content/70">{@product.subtitle}</p>
        </header>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="space-y-3">
            <div
              :for={image <- Enum.sort_by(@product.images || [], &{&1.position, &1.id})}
              class="rounded-xl border border-base-300 bg-base-200/50 p-3"
            >
              <img
                src={image.url}
                alt={image.alt || @product.title}
                class="h-56 w-full rounded-lg object-cover"
              />
            </div>

            <div
              :if={@product.images == []}
              class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
            >
              No product images available.
            </div>
          </div>

          <div class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-5">
            <p class="text-sm font-semibold">
              {format_money(@product.default_variant && @product.default_variant.price_minor)}
            </p>

            <p :if={@product.description} class="text-sm leading-6 text-base-content/80">
              {@product.description}
            </p>

            <.form for={@form} id="cart-line-form" phx-submit="queue_cart_line">
              <.input field={@form[:quantity]} type="number" min="1" label="Quantity" />
              <.button id="add-to-cart-handoff" type="submit" class="mt-3">
                Add to Cart
              </.button>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp format_money(nil), do: "Price unavailable"

  defp format_money(minor) when is_integer(minor),
    do: "$#{:erlang.float_to_binary(minor / 100, decimals: 2)}"
end
