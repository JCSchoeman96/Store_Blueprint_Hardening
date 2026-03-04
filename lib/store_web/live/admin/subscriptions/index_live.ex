defmodule StoreWeb.Admin.Subscriptions.IndexLive do
  @moduledoc """
  Admin subscription listing surface.
  """

  use StoreWeb, :live_view

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias StoreWeb.Params.Subscriptions.AdminSubscriptionIndexParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, subscriptions: [], query_error: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, query} <- AdminSubscriptionIndexParams.query(params),
         {:ok, subscriptions} <- SubscriptionsFacade.list_subscriptions_for_admin(actor, query) do
      {:noreply, assign(socket, subscriptions: subscriptions, query_error: nil)}
    else
      {:error, error} ->
        {:noreply, assign(socket, subscriptions: [], query_error: error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="admin-subscriptions-index"
        class="space-y-4 rounded-xl border border-base-300 bg-base-200/50 p-6"
      >
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Admin Subscriptions</h1>
          <p class="text-sm text-base-content/70">Read-only support and operations visibility.</p>
        </header>

        <p
          :if={@query_error}
          class="rounded border border-error/40 bg-error/10 p-3 text-sm text-error"
        >
          Unable to load subscription list.
        </p>

        <div :if={@subscriptions == []} class="rounded border border-base-300 bg-base-100 p-4 text-sm">
          No subscriptions found.
        </div>

        <ul :if={@subscriptions != []} class="space-y-2">
          <li
            :for={subscription <- @subscriptions}
            class="rounded border border-base-300 bg-base-100 p-3 text-sm"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="font-medium">{subscription.id}</div>
              <span class="uppercase tracking-wide text-base-content/70">{subscription.status}</span>
            </div>
            <div class="mt-1 text-base-content/70">
              user: {subscription.user_id} | provider: {subscription.provider}
            </div>
            <div class="mt-2">
              <.link navigate={~p"/admin/subscriptions/#{subscription.id}"} class="btn btn-sm">
                View
              </.link>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
