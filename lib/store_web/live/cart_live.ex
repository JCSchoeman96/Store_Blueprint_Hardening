defmodule StoreWeb.CartLive do
  @moduledoc """
  Cart LiveView for guest and authenticated users.
  """

  use StoreWeb, :live_view

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Checkout
  alias StoreWeb.Params.Carts.CartItemParams
  alias StoreWeb.Params.Checkout.CheckoutStartParams

  @impl true
  def mount(_params, session, socket) do
    cart_token = Map.get(session, "cart_token")

    {:ok,
     socket
     |> assign(:cart_token, cart_token)
     |> assign(:cart_view, empty_cart_view())
     |> load_cart_view()}
  end

  @impl true
  def handle_event("update_qty", %{"variant_id" => variant_id, "qty" => qty}, socket) do
    actor = socket.assigns[:current_user]

    with {:ok, input} <- CartItemParams.input(%{"variant_id" => variant_id, "qty" => qty}),
         {:ok, _cart} <-
           CartsFacade.update_item_qty_for_user(actor, socket.assigns.cart_token, input) do
      {:noreply, socket |> put_flash(:info, "Cart updated") |> load_cart_view()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unable to update cart item")}
    end
  end

  @impl true
  def handle_event("remove_item", %{"variant_id" => variant_id}, socket) do
    actor = socket.assigns[:current_user]

    case CartsFacade.remove_item_for_user(actor, socket.assigns.cart_token, variant_id) do
      {:ok, _cart} ->
        {:noreply, socket |> put_flash(:info, "Item removed") |> load_cart_view()}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Unable to remove cart item")}
    end
  end

  @impl true
  def handle_event("start_checkout", _params, socket) do
    actor = socket.assigns[:current_user]

    with {:ok, input} <- CheckoutStartParams.input(%{}),
         {:ok, result} <- Checkout.start_from_cart(actor, socket.assigns.cart_token, input) do
      {:noreply, push_navigate(socket, to: ~p"/checkout?checkout_key=#{result.checkout_key}")}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to start checkout")
         |> load_cart_view()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="cart-live" class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Your Cart</h1>
          <p class="text-sm text-base-content/70">Review items and start checkout.</p>
        </header>

        <div
          :if={@cart_view.items == []}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          Your cart is empty.
        </div>

        <div :if={@cart_view.items != []} class="space-y-3">
          <article
            :for={item <- @cart_view.items}
            id={"cart-item-#{item.variant_id}"}
            class="rounded-xl border border-base-300 bg-base-200/50 p-4"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-base font-semibold">{item.product_title || "Product"}</h2>
                <p class="text-xs text-base-content/60">{item.sku || item.variant_id}</p>
                <p :if={item.variant_title} class="text-sm text-base-content/70">
                  {item.variant_title}
                </p>
                <p class="mt-2 text-sm font-semibold">
                  {format_money(item.price_minor, item.currency_code)}
                </p>
              </div>

              <div class="flex flex-col items-end gap-2">
                <form phx-submit="update_qty" class="flex items-center gap-2">
                  <input type="hidden" name="variant_id" value={item.variant_id} />
                  <input
                    id={"qty-#{item.variant_id}"}
                    type="number"
                    name="qty"
                    min="1"
                    max="99"
                    value={item.qty}
                    class="w-20 rounded-md border border-base-300 bg-base-100 px-2 py-1"
                  />
                  <.button type="submit" id={"save-qty-#{item.variant_id}"}>Save</.button>
                </form>

                <button
                  id={"remove-#{item.variant_id}"}
                  phx-click="remove_item"
                  phx-value-variant_id={item.variant_id}
                  class="text-xs text-red-600 hover:underline"
                >
                  Remove
                </button>
              </div>
            </div>
          </article>

          <div class="rounded-xl border border-base-300 bg-base-200/50 p-4">
            <div class="flex items-center justify-between text-sm">
              <span>Total items</span>
              <span class="font-semibold">{@cart_view.item_count}</span>
            </div>
            <div class="mt-2 flex items-center justify-between text-sm">
              <span>Subtotal</span>
              <span class="font-semibold">
                {format_money(@cart_view.subtotal_minor, cart_currency(@cart_view))}
              </span>
            </div>

            <.button id="start-checkout" phx-click="start_checkout" class="mt-4 w-full">
              Start Checkout
            </.button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_cart_view(socket) do
    actor = socket.assigns[:current_user]

    with {:ok, query} <- CartLoadQuery.new(%{"include_items" => true}),
         {:ok, cart_view} <-
           CartsFacade.get_cart_view_for_user(actor, socket.assigns.cart_token, query) do
      assign(socket, :cart_view, cart_view)
    else
      _ ->
        socket
        |> put_flash(:error, "Unable to load cart")
        |> assign(:cart_view, empty_cart_view())
    end
  end

  defp empty_cart_view do
    %{items: [], item_count: 0, subtotal_minor: 0, version: 1}
  end

  defp cart_currency(%{items: [%{currency_code: currency} | _]}), do: currency
  defp cart_currency(_cart_view), do: "USD"

  defp format_money(nil, _currency), do: "Price unavailable"

  defp format_money(minor, currency) when is_integer(minor) do
    code = if is_binary(currency), do: String.upcase(currency), else: "USD"
    "#{code} #{:erlang.float_to_binary(minor / 100, decimals: 2)}"
  end
end
