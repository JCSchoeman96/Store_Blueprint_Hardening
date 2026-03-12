defmodule StoreWeb.CartLive do
  @moduledoc """
  Cart LiveView for guest and authenticated users.
  """

  use StoreWeb, :live_view

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Checkout
  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats
  alias StoreWeb.Live.StaticToLive
  alias StoreWeb.Params.Carts.CartItemParams
  alias StoreWeb.Params.Checkout.CheckoutStartParams

  @mount_event [:store, :cart_live, :mount]

  @impl true
  def mount(_params, session, socket) do
    started_at = System.monotonic_time()
    cart_token = Map.get(session, "cart_token")

    socket =
      socket
      |> assign(:cart_token, cart_token)
      |> assign(:cart_view, empty_cart_view())
      |> assign(:hydrating?, true)

    if connected?(socket) do
      {socket, jitter_ms} =
        StaticToLive.schedule_warm_load(socket, :load_warm_cart, jitter?: true, key: cart_token)

      {:ok, assign(socket, :warm_load_jitter_ms, jitter_ms)}
    else
      StaticToLive.emit_mount_telemetry(
        @mount_event,
        started_at,
        %{jitter_delay_ms: 0},
        %{phase: :static, result: :ok}
      )

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("update_qty", %{"variant_id" => variant_id, "qty" => qty}, socket) do
    actor = socket.assigns[:current_user]

    with {:ok, input} <- CartItemParams.input(%{"variant_id" => variant_id, "qty" => qty}),
         {:ok, _cart} <-
           CartsFacade.update_item_qty_for_user(actor, socket.assigns.cart_token, input) do
      {:noreply, socket |> put_flash(:info, "Cart updated") |> load_cart_view_now()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unable to update cart item")}
    end
  end

  @impl true
  def handle_event("remove_item", %{"variant_id" => variant_id}, socket) do
    actor = socket.assigns[:current_user]

    case CartsFacade.remove_item_for_user(actor, socket.assigns.cart_token, variant_id) do
      {:ok, _cart} ->
        {:noreply, socket |> put_flash(:info, "Item removed") |> load_cart_view_now()}

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
      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, checkout_start_error_message(error))
         |> load_cart_view_now()}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to start checkout")
         |> load_cart_view_now()}
    end
  end

  @impl true
  def handle_info(:load_warm_cart, socket) do
    started_at = System.monotonic_time()
    {socket, repo_stats, result} = load_cart_view_with_stats(socket)

    StaticToLive.emit_mount_telemetry(
      @mount_event,
      started_at,
      Map.merge(repo_stats, %{jitter_delay_ms: Map.get(socket.assigns, :warm_load_jitter_ms, 0)}),
      %{phase: :live, result: result}
    )

    {:noreply, assign(socket, :hydrating?, false)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
          :if={@hydrating? and @cart_view.items == []}
          class="rounded-xl border border-base-300 bg-base-200/50 p-6 text-sm"
        >
          Loading your cart...
        </div>

        <div
          :if={!@hydrating? and @cart_view.items == []}
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

  defp load_cart_view_now(socket) do
    {socket, _repo_stats, _result} = load_cart_view_with_stats(socket)
    assign(socket, :hydrating?, false)
  end

  defp load_cart_view_with_stats(socket) do
    actor = socket.assigns[:current_user]

    {result, repo_stats} =
      RepoStats.capture(fn ->
        case CartLoadQuery.new(%{"include_items" => true}) do
          {:ok, query} ->
            CartsFacade.get_cart_view_for_user(actor, socket.assigns.cart_token, query)

          error ->
            error
        end
      end)

    case result do
      {:ok, cart_view} ->
        {assign(socket, :cart_view, cart_view), repo_stats, :ok}

      _ ->
        {socket
         |> put_flash(:error, "Unable to load cart")
         |> assign(:cart_view, empty_cart_view()), repo_stats, :error}
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

  defp checkout_start_error_message(error) do
    case Normalize.normalize(error).code do
      "STALE_RECORD" ->
        "Your cart changed during checkout. Please try again."

      "CHECKOUT_DUPLICATE" ->
        "Checkout is already in progress for this cart. Please try again."

      "RESERVATION_CONFLICT" ->
        "Checkout is busy right now. Please retry in a moment."

      "OUT_OF_STOCK" ->
        "One or more items are no longer available. Review your cart and try again."

      _ ->
        "Unable to start checkout"
    end
  end
end
