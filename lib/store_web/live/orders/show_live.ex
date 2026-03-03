defmodule StoreWeb.Orders.ShowLive do
  @moduledoc """
  Customer order detail with fulfillment/shipment timeline by order_ref.
  """

  use StoreWeb, :live_view

  alias Store.Orders.Facade, as: OrdersFacade

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :order_detail, nil)}
  end

  @impl true
  def handle_params(%{"order_ref" => order_ref}, _uri, socket) do
    actor = socket.assigns.current_user

    case OrdersFacade.get_order_detail_for_user(actor, order_ref) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> put_flash(:error, "Order not found")
         |> push_navigate(to: ~p"/account")}

      {:ok, detail} ->
        {:noreply, assign(socket, :order_detail, detail)}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load order")
         |> push_navigate(to: ~p"/account")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        :if={@order_detail}
        id="order-detail"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="space-y-1">
          <h1 class="text-2xl font-semibold">Order {@order_detail.order.order_ref}</h1>
          <p class="text-sm text-base-content/70">State: {@order_detail.order.state}</p>
        </div>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Items</h2>
          <ul class="space-y-2 text-sm">
            <li
              :for={item <- @order_detail.line_items}
              class="rounded border border-base-300 bg-base-100 p-3"
            >
              <div class="font-medium">{item.product_title_snapshot}</div>
              <div>{item.variant_title_snapshot || item.sku_snapshot}</div>
              <div>Qty: {item.quantity}</div>
            </li>
          </ul>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Fulfillment Timeline</h2>
          <div :if={is_nil(@order_detail.fulfillment_order)} class="text-sm text-base-content/70">
            Fulfillment not created yet.
          </div>
          <div :if={@order_detail.fulfillment_order} class="space-y-2 text-sm">
            <p>
              Fulfillment State:
              <span class="font-semibold">{@order_detail.fulfillment_order.state}</span>
            </p>
            <ul class="space-y-2">
              <li
                :for={shipment <- @order_detail.shipments}
                class="rounded border border-base-300 bg-base-100 p-3"
              >
                <div>Shipment State: <span class="font-semibold">{shipment.state}</span></div>
                <div>Carrier: {shipment.carrier || "-"}</div>
                <div>Tracking: {shipment.tracking_ref || "-"}</div>
                <div>Updated: {shipment.updated_at}</div>
              </li>
            </ul>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
