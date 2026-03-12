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
       |> assign(:query, %AdminFulfillmentQueueQuery{
         limit: 20,
         after: nil,
         before: nil,
         state: nil
       })
       |> assign(:page, nil)
       |> assign(:next_cursor, nil)
       |> assign(:previous_cursor, nil)
       |> stream(:fulfillment_orders, [])}
    else
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- FulfillmentQueueParams.index_query(extract_query_params(uri)),
         {:ok, page} <-
           FulfillmentFacade.list_fulfillment_orders_for_admin(actor, query) do
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:page, page)
       |> assign(:next_cursor, next_cursor(page))
       |> assign(:previous_cursor, previous_cursor(query, page))
       |> stream(:fulfillment_orders, page.results, reset: true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load fulfillment queue")
         |> assign(:page, nil)
         |> assign(:next_cursor, nil)
         |> assign(:previous_cursor, nil)
         |> stream(:fulfillment_orders, [], reset: true)}
    end
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    params =
      socket.assigns.query
      |> query_to_params()
      |> Map.drop(["after", "before"])
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

        <div class="flex items-center justify-end gap-2">
          <.link
            :if={@previous_cursor}
            patch={~p"/admin/fulfillment?#{page_params(@query, %{before: @previous_cursor})}"}
            class="rounded-lg border border-base-content/20 px-3 py-2 text-sm hover:bg-base-300"
          >
            Previous
          </.link>
          <.link
            :if={@next_cursor}
            patch={~p"/admin/fulfillment?#{page_params(@query, %{after: @next_cursor})}"}
            class="rounded-lg border border-base-content/20 px-3 py-2 text-sm hover:bg-base-300"
          >
            Next
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp refresh_with_flash(socket, kind, message) do
    socket
    |> put_flash(kind, message)
    |> push_patch(to: ~p"/admin/fulfillment?#{query_to_params(socket.assigns.query)}")
  end

  defp query_to_params(nil), do: %{"limit" => "20"}

  defp query_to_params(query) do
    %{"limit" => to_string(query.limit)}
    |> put_state_filter(query.state)
    |> maybe_put("after", query.after)
    |> maybe_put("before", query.before)
  end

  defp page_params(query, cursor_updates) do
    query
    |> query_to_params()
    |> Map.drop(["after", "before"])
    |> maybe_put("after", Map.get(cursor_updates, :after))
    |> maybe_put("before", Map.get(cursor_updates, :before))
  end

  defp put_state_filter(params, nil), do: Map.delete(params, "state")
  defp put_state_filter(params, ""), do: Map.delete(params, "state")
  defp put_state_filter(params, state), do: Map.put(params, "state", to_string(state))

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, to_string(value))

  defp next_cursor(%Ash.Page.Keyset{more?: true, results: results}) do
    results
    |> List.last()
    |> case do
      nil -> nil
      result -> result.__metadata__.keyset
    end
  end

  defp next_cursor(_page), do: nil

  defp previous_cursor(%AdminFulfillmentQueueQuery{after: nil, before: nil}, _page), do: nil

  defp previous_cursor(_query, %Ash.Page.Keyset{results: [first | _rest]}),
    do: first.__metadata__.keyset

  defp previous_cursor(_query, _page), do: nil

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
