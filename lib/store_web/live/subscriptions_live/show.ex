defmodule StoreWeb.SubscriptionsLive.Show do
  @moduledoc """
  Authenticated subscription detail.
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

    case SubscriptionsFacade.get_subscription_for_user(actor, id) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> put_flash(:error, "Subscription not found")
         |> push_navigate(to: ~p"/account/subscriptions")}

      {:ok, subscription} ->
        {:noreply, assign(socket, :subscription, subscription)}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to load subscription")
         |> push_navigate(to: ~p"/account/subscriptions")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        :if={@subscription}
        id="account-subscription-detail"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">
            Subscription {(@subscription.subscription_plan && @subscription.subscription_plan.key) ||
              @subscription.id}
          </h1>
          <p class="text-sm text-base-content/70">Status: {@subscription.status}</p>
        </header>

        <dl class="grid gap-3 text-sm md:grid-cols-2">
          <div>
            <dt class="text-base-content/70">Provider</dt>
            <dd class="font-medium">{@subscription.provider}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Billing Mode</dt>
            <dd class="font-medium">{@subscription.billing_mode}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Current Period Start</dt>
            <dd>{format_datetime(@subscription.current_period_start_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Current Period End</dt>
            <dd>{format_datetime(@subscription.current_period_end_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Next Renewal</dt>
            <dd>{format_datetime(@subscription.next_renewal_at)}</dd>
          </div>
          <div>
            <dt class="text-base-content/70">Cancel At Period End</dt>
            <dd>{if @subscription.cancel_at_period_end, do: "yes", else: "no"}</dd>
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
              <div>Qty: {item.quantity}</div>
              <div>
                Price snapshot: {item.currency_snapshot} {item.amount_minor_snapshot}
              </div>
              <div>Interval: {item.interval_count_snapshot} {item.interval_unit_snapshot}</div>
            </li>
          </ul>
        </section>

        <.link navigate={~p"/account/subscriptions"} class="btn btn-sm">Back</.link>
      </section>
    </Layouts.app>
    """
  end

  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "-"
end
