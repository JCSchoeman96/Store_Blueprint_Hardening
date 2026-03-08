defmodule StoreWeb.Live.EntitlementAware do
  @moduledoc """
  Shared entitlement cache subscription and refresh helpers for authenticated LiveViews.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, push_navigate: 2]

  alias Store.Entitlements.Cache, as: EntitlementsCache
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Entitlements.Types.EntitlementSet

  @spec maybe_subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_subscribe(socket) do
    current_user = socket.assigns[:current_user]

    if connected?(socket) and is_map(current_user) and is_binary(current_user.id) do
      Phoenix.PubSub.subscribe(Store.PubSub, EntitlementsCache.topic(current_user.id))
    end

    socket
  end

  @spec assign_entitlement_set(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_entitlement_set(socket) do
    case socket.assigns[:current_user] do
      %{id: user_id} = actor when is_binary(user_id) ->
        case EntitlementsFacade.entitlement_set_for_user(actor) do
          {:ok, entitlement_set} -> assign(socket, :entitlement_set, entitlement_set)
          {:error, _reason} -> assign(socket, :entitlement_set, nil)
        end

      _ ->
        assign(socket, :entitlement_set, nil)
    end
  end

  @spec handle_invalidation(Phoenix.LiveView.Socket.t(), term(), keyword()) ::
          {:handled, Phoenix.LiveView.Socket.t()} | :ignored
  def handle_invalidation(socket, message, opts \\ [])

  def handle_invalidation(
        socket,
        {:entitlements_invalidated, user_id, reason, occurred_at},
        opts
      )
      when is_binary(user_id) and is_list(opts) do
    current_user = socket.assigns[:current_user]

    if is_map(current_user) and current_user.id == user_id do
      socket =
        socket
        |> assign_entitlement_set()
        |> push_event("membership_expired", %{
          reason: reason,
          occurred_at: DateTime.to_iso8601(occurred_at)
        })
        |> maybe_redirect_after_invalidation(opts)

      {:handled, socket}
    else
      :ignored
    end
  end

  def handle_invalidation(_socket, _message, _opts), do: :ignored

  defp maybe_redirect_after_invalidation(socket, opts) do
    with {kind, scope_key} <- Keyword.get(opts, :required_entitlement),
         redirect_to when is_binary(redirect_to) <- Keyword.get(opts, :redirect_to),
         %{entitlement_set: entitlement_set} when not is_nil(entitlement_set) <- socket.assigns,
         false <- EntitlementSet.has_entitlement?(entitlement_set, kind, scope_key) do
      push_navigate(socket, to: redirect_to)
    else
      _ -> socket
    end
  end
end
