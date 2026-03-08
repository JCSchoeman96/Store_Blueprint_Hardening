defmodule StoreWeb.SubscriptionsLive.Index do
  @moduledoc """
  Authenticated subscriptions overview.
  """

  use StoreWeb, :live_view

  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias StoreWeb.Live.EntitlementAware
  alias StoreWeb.Params.Subscriptions.UserSubscriptionIndexParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> EntitlementAware.maybe_subscribe()
     |> EntitlementAware.assign_entitlement_set()
     |> assign(
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
         {:ok, entitlement_set} <- EntitlementsFacade.entitlement_set_for_user(actor) do
      {:noreply,
       assign(socket,
         subscriptions: subscriptions,
         entitlement_set: entitlement_set,
         entitlements: EntitlementSet.effective_grants(entitlement_set),
         query_error: nil
       )}
    else
      {:error, error} ->
        {:noreply, assign(socket, subscriptions: [], entitlements: [], query_error: error)}
    end
  end

  @impl true
  def handle_info(message, socket) do
    case EntitlementAware.handle_invalidation(socket, message) do
      {:handled, socket} ->
        entitlements =
          case socket.assigns[:entitlement_set] do
            nil -> []
            entitlement_set -> EntitlementSet.effective_grants(entitlement_set)
          end

        {:noreply, assign(socket, :entitlements, entitlements)}

      :ignored ->
        {:noreply, socket}
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
