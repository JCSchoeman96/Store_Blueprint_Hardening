defmodule StoreWeb.Admin.Subscriptions.ShowLive do
  @moduledoc """
  Admin subscription detail surface.
  """

  use StoreWeb, :live_view

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :subscription, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    actor = socket.assigns.current_user

    case SubscriptionsFacade.get_subscription_for_admin(actor, id) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> put_flash(:error, "Subscription not found")
         |> push_navigate(to: ~p"/admin/subscriptions")}

      {:ok, subscription} ->
        {:noreply, assign(socket, :subscription, subscription)}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load subscription")
         |> push_navigate(to: ~p"/admin/subscriptions")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        :if={@subscription}
        id="admin-subscription-detail"
        class="space-y-5 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Subscription {@subscription.id}</h1>
          <p class="text-sm text-base-content/70">User: {@subscription.user_id}</p>
        </header>

        <dl class="grid gap-3 text-sm md:grid-cols-2">
          <div>
            <dt class="text-base-content/70">Status</dt>
            <dd class="font-medium">{@subscription.status}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Provider</dt>
            <dd class="font-medium">{@subscription.provider}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Provider Subscription ID</dt>
            <dd>{@subscription.provider_subscription_id || "-"}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Provider Billing Ref</dt>
            <dd>{@subscription.provider_billing_ref || "-"}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Current Period End</dt>
            <dd>{format_datetime(@subscription.current_period_end_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Next Renewal</dt>
            <dd>{format_datetime(@subscription.next_renewal_at)}</dd>
          </div>
        </dl>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Items</h2>
          <div
            :if={@subscription.items == []}
            class="rounded border border-base-300 bg-base-100 p-3 text-sm"
          >
            No subscription items.
          </div>
          <ul :if={@subscription.items != []} class="space-y-2 text-sm">
            <li
              :for={item <- @subscription.items}
              class="rounded border border-base-300 bg-base-100 p-3"
            >
              <div>Variant: {item.variant_id}</div>
              <div>Quantity: {item.quantity}</div>
              <div>Plan key snapshot: {item.plan_key_snapshot}</div>
            </li>
          </ul>
        </section>

        <.link navigate={~p"/admin/subscriptions"} class="btn btn-sm">Back</.link>
      </section>
    </Layouts.app>
    """
  end

  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "-"
end
