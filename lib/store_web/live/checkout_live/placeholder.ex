defmodule StoreWeb.CheckoutLive.Placeholder do
  @moduledoc """
  Phase 21 checkout flow with shipping capture, totals finalization, and payment intent start.
  """

  use StoreWeb, :live_view

  alias Store.Checkout
  alias Store.Payments
  alias Store.Support.Errors.Normalize
  alias StoreWeb.Params.Checkout.{CheckoutFinalizeParams, CheckoutShippingParams}
  alias StoreWeb.Params.Payments.CreateIntentForOrderParams

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:checkout, nil)
     |> assign(:cart_token, Map.get(session, "cart_token"))
     |> assign(:checkout_key, nil)
     |> assign(:payment_intent, nil)}
  end

  @impl true
  def handle_params(%{"checkout_key" => checkout_key}, _uri, socket) do
    actor = checkout_actor(socket)

    case Checkout.get_checkout_for_user(actor, checkout_key) do
      {:ok, checkout} ->
        {:noreply,
         socket
         |> assign(:checkout_key, checkout_key)
         |> assign(:checkout, checkout)}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Checkout not found")
         |> push_navigate(to: ~p"/cart")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "checkout_key is required")
     |> push_navigate(to: ~p"/cart")}
  end

  @impl true
  def handle_event("set_shipping", params, socket) do
    if return_mode?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      with {:ok, input} <- CheckoutShippingParams.input(params),
           {:ok, checkout} <- Checkout.set_shipping(actor, socket.assigns.checkout_key, input) do
        {:noreply,
         socket
         |> assign(:checkout, checkout)
         |> put_flash(:info, "Shipping details saved")}
      else
        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :shipping))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to save shipping details")}
      end
    end
  end

  @impl true
  def handle_event("finalize_totals", _params, socket) do
    if return_mode?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      with {:ok, input} <- CheckoutFinalizeParams.input(%{}),
           {:ok, checkout} <- Checkout.finalize_totals(actor, socket.assigns.checkout_key, input) do
        {:noreply,
         socket
         |> assign(:checkout, checkout)
         |> put_flash(:info, "Totals finalized")}
      else
        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :finalize))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to finalize totals")}
      end
    end
  end

  @impl true
  def handle_event("create_payment_intent", params, socket) do
    if return_mode?(socket) do
      {:noreply, socket}
    else
      actor = checkout_actor(socket)

      with {:ok, input} <- CreateIntentForOrderParams.input(params),
           {:ok, intent} <-
             Payments.create_intent_for_order(actor, socket.assigns.checkout_key, input),
           {:ok, checkout} <- Checkout.get_checkout_for_user(actor, socket.assigns.checkout_key) do
        socket =
          socket
          |> assign(:payment_intent, intent)
          |> assign(:checkout, checkout)

        {:noreply, maybe_redirect_to_payment(socket, intent)}
      else
        {:error, error} ->
          {:noreply, put_flash(socket, :error, checkout_error_message(error, :payment_intent))}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to create payment intent")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="checkout-live" class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Checkout</h1>
          <p class="text-sm text-base-content/70">
            Review shipping, finalize totals, then continue to payment.
          </p>
        </header>

        <div
          :if={@live_action in [:return, :cancel]}
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm"
        >
          <p :if={@live_action == :return} class="font-semibold">
            Payment return received. This page is read-only and reflects the latest order state.
          </p>
          <p :if={@live_action == :cancel} class="font-semibold">
            Payment was canceled. This page is read-only and no payment state was applied from URL params.
          </p>
        </div>

        <div :if={@checkout} class="grid gap-4 lg:grid-cols-2">
          <article class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
            <h2 class="text-base font-semibold">Shipping</h2>

            <form :if={@live_action == :index} phx-submit="set_shipping" class="grid gap-3">
              <input
                name="recipient_name"
                value={@checkout.shipping_recipient_name || ""}
                placeholder="Recipient name"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="address_line1"
                value={@checkout.shipping_address_line1 || ""}
                placeholder="Address line 1"
                required
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="address_line2"
                value={@checkout.shipping_address_line2 || ""}
                placeholder="Address line 2"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <input
                name="city"
                value={@checkout.shipping_city || ""}
                placeholder="City"
                required
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <div class="grid gap-3 sm:grid-cols-3">
                <input
                  name="country_code"
                  value={@checkout.shipping_country_code || "US"}
                  placeholder="Country"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />

                <input
                  name="region_code"
                  value={@checkout.shipping_region_code || ""}
                  placeholder="Region"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />

                <input
                  name="postal_code"
                  value={@checkout.shipping_postal_code || ""}
                  placeholder="Postal"
                  required
                  class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                />
              </div>

              <input
                name="phone"
                value={@checkout.shipping_phone || ""}
                placeholder="Phone"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
              />

              <select
                name="shipping_method_code"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                required
              >
                <option value="">Select shipping method</option>
                <option
                  :for={option <- @checkout.shipping_quote_options || []}
                  value={option.shipping_method_code}
                  selected={option.shipping_method_code == @checkout.shipping_method_code}
                >
                  {option.shipping_method_code}
                </option>
              </select>

              <select
                name="quote_hash"
                class="rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                required
              >
                <option value="">Select shipping quote</option>
                <option
                  :for={option <- @checkout.shipping_quote_options || []}
                  value={option.quote_hash}
                  selected={option.quote_hash == @checkout.shipping_quote_hash}
                >
                  {quote_label(option)}
                </option>
              </select>

              <p
                :if={Enum.empty?(@checkout.shipping_quote_options || [])}
                class="text-xs text-warning"
              >
                No eligible shipping quotes yet. Check destination fields.
              </p>

              <.button id="save-shipping" type="submit">Save Shipping</.button>
            </form>

            <div :if={@live_action != :index} class="space-y-1 text-sm">
              <p>{@checkout.shipping_recipient_name || "Recipient pending"}</p>
              <p>{@checkout.shipping_address_line1 || "Address pending"}</p>
              <p>{@checkout.shipping_city || "City pending"}</p>
            </div>
          </article>

          <article class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-4">
            <h2 class="text-base font-semibold">Summary</h2>

            <div class="space-y-2 text-sm">
              <div class="flex items-center justify-between">
                <span>Order</span>
                <span class="font-semibold">{@checkout.order_ref}</span>
              </div>

              <div class="flex items-center justify-between">
                <span>Items</span>
                <span class="font-semibold">{@checkout.item_count}</span>
              </div>

              <div class="flex items-center justify-between">
                <span>Items subtotal</span>
                <span class="font-semibold">
                  {format_money(@checkout.items_subtotal_minor, @checkout.currency_code)}
                </span>
              </div>

              <div class="flex items-center justify-between">
                <span>Shipping</span>
                <span class="font-semibold">
                  {format_money(@checkout.shipping_total_minor, @checkout.currency_code)}
                </span>
              </div>

              <div class="flex items-center justify-between">
                <span>Tax</span>
                <span class="font-semibold">
                  {format_money(@checkout.tax_total_minor, @checkout.currency_code)}
                </span>
              </div>

              <div class="mt-2 flex items-center justify-between border-t border-base-300 pt-2 text-base">
                <span class="font-semibold">Grand total</span>
                <span class="font-semibold">
                  {format_money(@checkout.grand_total_minor, @checkout.currency_code)}
                </span>
              </div>
            </div>

            <div :if={@live_action == :index} class="space-y-2">
              <.button id="finalize-totals" phx-click="finalize_totals" class="w-full">
                Finalize Totals
              </.button>

              <.button
                id="pay-now"
                phx-click="create_payment_intent"
                phx-value-provider="stripe"
                class="w-full"
                disabled={!@checkout.totals_finalized?}
              >
                Continue To Payment
              </.button>
            </div>

            <div
              :if={@payment_intent}
              class="rounded-lg border border-base-300 bg-base-100/70 p-3 text-xs"
            >
              <p>Payment intent: {@payment_intent.payment_intent_id}</p>
              <p>State: {@payment_intent.state}</p>
            </div>

            <.link
              :if={@live_action in [:return, :cancel]}
              navigate={~p"/checkout?checkout_key=#{@checkout.checkout_key}"}
              class="inline-flex rounded-lg border border-base-content/30 px-3 py-2 text-sm font-medium hover:bg-base-300"
            >
              Back to Checkout
            </.link>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp format_money(minor, currency) when is_integer(minor) do
    code = if is_binary(currency) and currency != "", do: String.upcase(currency), else: "USD"
    "#{code} #{:erlang.float_to_binary(minor / 100, decimals: 2)}"
  end

  defp format_money(_minor, _currency), do: "USD 0.00"

  defp quote_label(option) do
    method = option.label || option.shipping_method_code
    "#{method} - #{format_money(option.amount_minor, option.currency_code)}"
  end

  defp checkout_actor(socket) do
    user = socket.assigns[:current_user]
    token = socket.assigns[:cart_token]

    cond do
      is_map(user) and is_binary(token) ->
        Map.put(user, :cart_token, token)

      is_map(user) ->
        user

      is_binary(token) ->
        %{cart_token: token}

      true ->
        nil
    end
  end

  defp return_mode?(socket) do
    socket.assigns.live_action in [:return, :cancel]
  end

  defp checkout_error_message(error, context) do
    case Normalize.normalize(error).code do
      "STALE_RECORD" ->
        "Your checkout changed while processing. Please retry."

      "CHECKOUT_DUPLICATE" ->
        "This checkout is already in progress. Please refresh and retry."

      "RESERVATION_CONFLICT" ->
        reservation_conflict_message(context)

      "OUT_OF_STOCK" ->
        "One or more items are no longer available. Review your cart and try again."

      _ ->
        fallback_checkout_error_message(context)
    end
  end

  defp reservation_conflict_message(:payment_intent),
    do: "Checkout is busy right now. Please retry payment in a moment."

  defp reservation_conflict_message(_context),
    do: "Checkout is busy right now. Please retry in a moment."

  defp fallback_checkout_error_message(:shipping), do: "Unable to save shipping details"
  defp fallback_checkout_error_message(:finalize), do: "Unable to finalize totals"
  defp fallback_checkout_error_message(:payment_intent), do: "Unable to create payment intent"

  defp maybe_redirect_to_payment(socket, %{redirect_url: url})
       when is_binary(url) and url != "" do
    redirect(socket, external: url)
  end

  defp maybe_redirect_to_payment(socket, _intent) do
    put_flash(socket, :info, "Payment intent created")
  end
end
