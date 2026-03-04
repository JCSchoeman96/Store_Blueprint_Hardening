defmodule StoreWeb.SubscriptionsLive.Index do
  @moduledoc """
  Authenticated subscriptions overview.
  """

  use StoreWeb, :live_view

  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias StoreWeb.Params.Entitlements.UserEntitlementIndexParams
  alias StoreWeb.Params.Subscriptions.UserSubscriptionIndexParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       subscriptions: [],
       entitlements: [],
       query_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, sub_query} <- UserSubscriptionIndexParams.query(params),
         {:ok, subscriptions} <- SubscriptionsFacade.list_subscriptions_for_user(actor, sub_query),
         {:ok, entitlement_query} <-
           UserEntitlementIndexParams.query(%{"status" => "active", "limit" => 200}),
         {:ok, entitlements} <-
           EntitlementsFacade.list_entitlements_for_user(actor, entitlement_query) do
      {:noreply,
       assign(socket,
         subscriptions: subscriptions,
         entitlements: entitlements,
         query_error: nil
       )}
    else
      {:error, error} ->
        {:noreply, assign(socket, subscriptions: [], entitlements: [], query_error: error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="account-subscriptions"
        class="space-y-6 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">My Subscriptions</h1>
          <p class="text-sm text-base-content/70">Read-only status and entitlement evidence.</p>
        </header>

        <p
          :if={@query_error}
          class="rounded border border-error/40 bg-error/10 p-3 text-sm text-error"
        >
          Unable to load subscriptions right now.
        </p>

        <div :if={@subscriptions == []} class="rounded border border-base-300 bg-base-100 p-4 text-sm">
          No subscriptions found.
        </div>

        <ul :if={@subscriptions != []} class="space-y-3">
          <li
            :for={subscription <- @subscriptions}
            class="rounded border border-base-300 bg-base-100 p-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="font-medium">
                {(subscription.subscription_plan && subscription.subscription_plan.name) ||
                  (subscription.subscription_plan && subscription.subscription_plan.key) ||
                  "Subscription"}
              </div>
              <span class="text-xs uppercase tracking-wide text-base-content/70">
                {subscription.status}
              </span>
            </div>
            <div class="mt-2 text-sm text-base-content/70">
              <p>Provider: {subscription.provider}</p>
              <p>
                Period: {format_datetime(subscription.current_period_start_at)} -> {format_datetime(
                  subscription.current_period_end_at
                )}
              </p>
              <p :if={subscription.cancel_at_period_end}>Cancels at period end</p>
            </div>
            <div class="mt-3">
              <.link navigate={~p"/account/subscriptions/#{subscription.id}"} class="btn btn-sm">
                View Details
              </.link>
            </div>
          </li>
        </ul>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Active Entitlements</h2>
          <div
            :if={@entitlements == []}
            class="rounded border border-base-300 bg-base-100 p-4 text-sm"
          >
            No active entitlements.
          </div>
          <ul :if={@entitlements != []} class="space-y-2 text-sm">
            <li :for={grant <- @entitlements} class="rounded border border-base-300 bg-base-100 p-3">
              <div class="font-medium">{grant.kind}</div>
              <div>{grant.scope_key}</div>
              <div class="text-base-content/70">
                Valid to: {format_datetime(grant.valid_to_at)}
              </div>
            </li>
          </ul>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "-"
end
