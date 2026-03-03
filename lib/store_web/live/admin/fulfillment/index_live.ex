defmodule StoreWeb.Admin.Fulfillment.IndexLive do
  @moduledoc """
  Admin/support fulfillment queue with state transitions through facade surfaces only.
  """

  use StoreWeb, :live_view

  alias Store.Admin.Authorization
  alias Store.Fulfillment.Facade, as: FulfillmentFacade
  alias Store.Fulfillment.Queries.AdminFulfillmentQueueQuery
  alias StoreWeb.Params.Admin.FulfillmentQueueParams

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Authorization.has_any_role?(actor, [:super_admin, :admin, :support]) do
      {:ok,
       socket
       |> assign(:query, %AdminFulfillmentQueueQuery{limit: 20, offset: 0, state: nil})
       |> stream(:fulfillment_orders, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- FulfillmentQueueParams.index_query(extract_query_params(uri)),
         {:ok, fulfillment_orders} <-
           FulfillmentFacade.list_fulfillment_orders_for_admin(actor, query) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> stream(:fulfillment_orders, fulfillment_orders, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load fulfillment queue")
         |> stream(:fulfillment_orders, [], reset: true)}
    end
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    params =
      socket.assigns.query
      |> query_to_params()
      |> put_state_filter(state)

    {:noreply, push_patch(socket, to: ~p"/admin/fulfillment?#{params}")}
  end

  @impl true
  def handle_event("mark_packed", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    case FulfillmentFacade.mark_packed_for_support(actor, id) do
      {:ok, _} ->
        {:noreply, refresh_with_flash(socket, :info, "Fulfillment marked packed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to mark packed")}
    end
  end

  @impl true
  def handle_event("mark_shipped", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    case FulfillmentFacade.mark_shipped_for_support(actor, id, %{}) do
      {:ok, _} ->
        {:noreply, refresh_with_flash(socket, :info, "Fulfillment marked shipped")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to mark shipped")}
    end
  end

  @impl true
  def handle_event("mark_delivered", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    case FulfillmentFacade.mark_delivered_for_support(actor, id) do
      {:ok, _} ->
        {:noreply, refresh_with_flash(socket, :info, "Fulfillment marked delivered")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to mark delivered")}
    end
  end

  @impl true
  def handle_event("cancel_fulfillment", %{"id" => id}, socket) do
    actor = socket.assigns.current_user
    attrs = %{notes: "Canceled by admin"}

    case FulfillmentFacade.cancel_fulfillment_for_admin(actor, id, attrs) do
      {:ok, _} ->
        {:noreply, refresh_with_flash(socket, :info, "Fulfillment canceled")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cancel denied. Step-up may be required.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-fulfillment-queue"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">Fulfillment Queue</h1>
            <p class="text-sm text-base-content/70">
              Paid + finalized physical orders waiting on operational transitions.
            </p>
          </div>
        </div>

        <form id="fulfillment-state-filter-form" phx-change="filter_state" class="max-w-sm">
          <label class="label mb-1 text-sm font-medium">Filter by State</label>
          <select name="state" class="select w-full">
            <option value="">All States</option>
            <option value="pending" selected={@query.state == :pending}>pending</option>
            <option value="packed" selected={@query.state == :packed}>packed</option>
            <option value="shipped" selected={@query.state == :shipped}>shipped</option>
            <option value="delivered" selected={@query.state == :delivered}>delivered</option>
            <option value="canceled" selected={@query.state == :canceled}>canceled</option>
          </select>
        </form>

        <.table
          id="fulfillment-orders"
          rows={@streams.fulfillment_orders}
          row_id={fn {id, _order} -> id end}
          row_item={fn {_id, order} -> order end}
        >
          <:col :let={order} label="Order ID">{order.order_id}</:col>
          <:col :let={order} label="State">{order.state}</:col>
          <:col :let={order} label="Method">{order.shipping_method_code}</:col>
          <:col :let={order} label="Created">{order.inserted_at}</:col>
          <:action :let={order}>
            <.button id={"pack-#{order.id}"} phx-click="mark_packed" phx-value-id={order.id}>
              Pack
            </.button>
          </:action>
          <:action :let={order}>
            <.button id={"ship-#{order.id}"} phx-click="mark_shipped" phx-value-id={order.id}>
              Ship
            </.button>
          </:action>
          <:action :let={order}>
            <.button
              id={"deliver-#{order.id}"}
              phx-click="mark_delivered"
              phx-value-id={order.id}
            >
              Deliver
            </.button>
          </:action>
          <:action :let={order}>
            <.button
              id={"cancel-#{order.id}"}
              phx-click="cancel_fulfillment"
              phx-value-id={order.id}
              class="btn btn-soft"
            >
              Cancel
            </.button>
          </:action>
        </.table>
      </section>
    </Layouts.app>
    """
  end

  defp refresh_with_flash(socket, kind, message) do
    socket
    |> put_flash(kind, message)
    |> push_patch(to: ~p"/admin/fulfillment?#{query_to_params(socket.assigns.query)}")
  end

  defp query_to_params(nil), do: %{"limit" => "20", "offset" => "0"}

  defp query_to_params(query) do
    %{"limit" => to_string(query.limit), "offset" => to_string(query.offset)}
    |> put_state_filter(query.state)
  end

  defp put_state_filter(params, nil), do: Map.delete(params, "state")
  defp put_state_filter(params, ""), do: Map.delete(params, "state")
  defp put_state_filter(params, state), do: Map.put(params, "state", to_string(state))

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
