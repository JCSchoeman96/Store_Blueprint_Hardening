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

  @max_schedule_chunk_ms 86_400_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> EntitlementAware.maybe_subscribe()
     |> EntitlementAware.assign_entitlement_set()
     |> assign(
       subscriptions: [],
       entitlements: [],
       query_error: nil,
       entitlement_boundary_timer_ref: nil,
       entitlement_boundary_generation: 0,
       entitlement_boundary_at: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user

    with {:ok, sub_query} <- UserSubscriptionIndexParams.query(params),
         {:ok, subscriptions} <- SubscriptionsFacade.list_subscriptions_for_user(actor, sub_query),
         {:ok, entitlement_set} <- EntitlementsFacade.entitlement_set_for_user(actor) do
      {:noreply,
       socket
       |> assign(:subscriptions, subscriptions)
       |> assign(:query_error, nil)
       |> replace_entitlement_projection(entitlement_set, utc_now())}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> assign(:subscriptions, [])
         |> assign(:query_error, error)
         |> replace_entitlement_projection(nil, utc_now())}
    end
  end

  @impl true
  def handle_info(
        {:timeout, timer_ref, {:entitlement_boundary, generation, boundary}},
        socket
      )
      when is_reference(timer_ref) and is_integer(generation) and is_struct(boundary, DateTime) do
    if timer_ref == socket.assigns[:entitlement_boundary_timer_ref] and
         generation == socket.assigns[:entitlement_boundary_generation] do
      as_of = utc_now()

      if DateTime.compare(boundary, as_of) == :gt do
        {:noreply, rearm_boundary_timer(socket, boundary, generation, as_of)}
      else
        {:noreply, refresh_at_boundary(socket, generation, as_of)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(message, socket) do
    case EntitlementAware.handle_invalidation(socket, message) do
      {:handled, socket} ->
        {:noreply,
         replace_entitlement_projection(socket, socket.assigns[:entitlement_set], utc_now())}

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

  defp replace_entitlement_projection(socket, %EntitlementSet{} = entitlement_set, as_of) do
    socket = cancel_boundary_timer(socket)
    generation = socket.assigns[:entitlement_boundary_generation] + 1

    socket =
      socket
      |> assign(:entitlement_set, entitlement_set)
      |> assign(:entitlements, EntitlementSet.effective_grants(entitlement_set, as_of))
      |> assign(:entitlement_boundary_generation, generation)
      |> assign(:entitlement_boundary_timer_ref, nil)
      |> assign(:entitlement_boundary_at, nil)

    schedule_next_boundary(socket, entitlement_set, generation, as_of)
  end

  defp replace_entitlement_projection(socket, nil, _as_of) do
    socket = cancel_boundary_timer(socket)
    generation = socket.assigns[:entitlement_boundary_generation] + 1

    socket
    |> assign(:entitlement_set, nil)
    |> assign(:entitlements, [])
    |> assign(:entitlement_boundary_generation, generation)
    |> assign(:entitlement_boundary_timer_ref, nil)
    |> assign(:entitlement_boundary_at, nil)
  end

  defp refresh_at_boundary(socket, generation, as_of) do
    case socket.assigns[:entitlement_set] do
      %EntitlementSet{} = entitlement_set ->
        socket
        |> assign(:entitlement_boundary_timer_ref, nil)
        |> assign(:entitlement_boundary_at, nil)
        |> assign(:entitlements, EntitlementSet.effective_grants(entitlement_set, as_of))
        |> schedule_next_boundary(entitlement_set, generation, as_of)

      _ ->
        socket
        |> assign(:entitlement_boundary_timer_ref, nil)
        |> assign(:entitlement_boundary_at, nil)
    end
  end

  defp schedule_next_boundary(socket, entitlement_set, generation, as_of) do
    case EntitlementSet.next_temporal_boundary(entitlement_set, as_of) do
      nil ->
        socket
        |> assign(:entitlement_boundary_timer_ref, nil)
        |> assign(:entitlement_boundary_at, nil)

      %DateTime{} = boundary ->
        scheduled_as_of = utc_now()

        if DateTime.compare(boundary, scheduled_as_of) == :gt do
          schedule_boundary_timer(socket, boundary, generation, scheduled_as_of)
        else
          socket
          |> assign(
            :entitlements,
            EntitlementSet.effective_grants(entitlement_set, scheduled_as_of)
          )
          |> schedule_next_boundary(entitlement_set, generation, scheduled_as_of)
        end
    end
  end

  defp schedule_boundary_timer(socket, boundary, generation, as_of) do
    if Phoenix.LiveView.connected?(socket) do
      remaining_ms =
        boundary
        |> DateTime.diff(as_of, :microsecond)
        |> then(&div(&1 + 999, 1_000))
        |> min(@max_schedule_chunk_ms)

      timer_ref =
        :erlang.start_timer(
          remaining_ms,
          self(),
          {:entitlement_boundary, generation, boundary}
        )

      socket
      |> assign(:entitlement_boundary_timer_ref, timer_ref)
      |> assign(:entitlement_boundary_at, boundary)
    else
      socket
      |> assign(:entitlement_boundary_timer_ref, nil)
      |> assign(:entitlement_boundary_at, nil)
    end
  end

  defp rearm_boundary_timer(socket, boundary, generation, as_of) do
    schedule_boundary_timer(socket, boundary, generation, as_of)
  end

  defp cancel_boundary_timer(socket) do
    case socket.assigns[:entitlement_boundary_timer_ref] do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _ -> :ok
    end

    socket
    |> assign(:entitlement_boundary_timer_ref, nil)
    |> assign(:entitlement_boundary_at, nil)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
