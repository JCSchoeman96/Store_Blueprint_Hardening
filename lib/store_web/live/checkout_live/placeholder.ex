defmodule StoreWeb.CheckoutLive.Placeholder do
  @moduledoc """
  Phase 20 checkout placeholder (read-only) resolved by checkout_key.
  """

  use StoreWeb, :live_view

  alias Store.Checkout

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:draft, nil)
     |> assign(:cart_token, Map.get(session, "cart_token"))}
  end

  @impl true
  def handle_params(%{"checkout_key" => checkout_key}, _uri, socket) do
    actor = checkout_actor(socket)

    case Checkout.get_draft_for_user(actor, checkout_key) do
      {:ok, draft} ->
        {:noreply, assign(socket, :draft, draft)}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Checkout draft not found")
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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="checkout-placeholder" class="space-y-6">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold">Checkout</h1>
          <p class="text-sm text-base-content/70">
            Phase 20 placeholder: pricing, shipping, and payment arrive in Phase 21.
          </p>
        </header>

        <div :if={@draft} class="space-y-3 rounded-xl border border-base-300 bg-base-200/50 p-4">
          <p class="text-xs uppercase tracking-wide text-base-content/60">checkout_key</p>
          <p class="break-all text-sm font-mono">{@draft.checkout_key}</p>

          <div class="grid gap-2 text-sm sm:grid-cols-2">
            <p>Cart version: <span class="font-semibold">{@draft.cart_version}</span></p>
            <p>Status: <span class="font-semibold">{@draft.status}</span></p>
            <p>Items: <span class="font-semibold">{@draft.item_count}</span></p>
            <p>Subtotal: <span class="font-semibold">{format_money(@draft.subtotal_minor)}</span></p>
          </div>

          <div class="rounded-lg border border-base-300 bg-base-100/60 p-3 text-xs text-base-content/70">
            This page is read-only. No pricing snapshots, reservations, or payment intents are created here in Phase 20.
          </div>

          <.link
            navigate={~p"/cart"}
            class="inline-flex rounded-lg border border-base-content/30 px-3 py-2 text-sm font-medium hover:bg-base-300"
          >
            Back to Cart
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp format_money(minor) when is_integer(minor),
    do: "USD #{:erlang.float_to_binary(minor / 100, decimals: 2)}"

  defp format_money(_), do: "USD 0.00"

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
end
