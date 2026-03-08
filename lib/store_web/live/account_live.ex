defmodule StoreWeb.AccountLive do
  @moduledoc """
  Minimal authenticated page used to prove LiveView auth guards.
  """

  use StoreWeb, :live_view
  alias StoreWeb.Live.EntitlementAware

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> EntitlementAware.maybe_subscribe()
     |> EntitlementAware.assign_entitlement_set()}
  end

  @impl true
  def handle_info(message, socket) do
    case EntitlementAware.handle_invalidation(socket, message) do
      {:handled, socket} -> {:noreply, socket}
      :ignored -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="account-protected"
        class="rounded-xl border border-neutral-700 bg-neutral-900/80 p-6"
      >
        <p class="text-sm text-neutral-300">Protected account area</p>
        <h1 class="mt-2 text-2xl font-semibold text-neutral-100">
          Signed in as {@current_user.email}
        </h1>
        <div class="mt-4 flex flex-wrap gap-2">
          <.link navigate={~p"/account/downloads"} class="btn btn-sm">
            Downloads
          </.link>
          <.link navigate={~p"/account/subscriptions"} class="btn btn-sm">
            Subscriptions
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
