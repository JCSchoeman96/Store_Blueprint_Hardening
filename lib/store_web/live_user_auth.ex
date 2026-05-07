defmodule StoreWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use StoreWeb, :verified_routes
  alias AshAuthentication.Phoenix.LiveSession
  alias Store.Admin.Authorization
  alias Store.Carts.Facade, as: CartsFacade

  def on_mount(:current_user, _params, session, socket) do
    socket =
      socket
      |> LiveSession.assign_new_resources(session)
      |> put_step_up_assign(session)
      |> maybe_merge_cart_token(session)

    {:cont, socket}
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    socket =
      socket
      |> put_step_up_assign(session)
      |> maybe_merge_cart_token(session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket =
      socket
      |> put_step_up_assign(session)
      |> maybe_merge_cart_token(session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_admin_required, _params, session, socket) do
    socket =
      socket
      |> put_step_up_assign(session)
      |> maybe_merge_cart_token(session)

    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}

      Authorization.has_any_role?(socket.assigns.current_user, [:super_admin, :admin, :support]) ->
        {:cont, socket}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket =
      socket
      |> put_step_up_assign(session)
      |> maybe_merge_cart_token(session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  defp put_step_up_assign(socket, session) when is_map(session) do
    assign(socket, :step_up_at_mono_usec, parse_step_up(Map.get(session, "step_up_at_mono_usec")))
  end

  defp put_step_up_assign(socket, _session), do: assign(socket, :step_up_at_mono_usec, nil)

  defp parse_step_up(value) when is_integer(value), do: value

  defp parse_step_up(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_step_up(_), do: nil

  defp maybe_merge_cart_token(socket, session) when is_map(session) do
    user = socket.assigns[:current_user]
    token = Map.get(session, "cart_token")

    if is_map(user) and is_binary(token) do
      _ = CartsFacade.merge_token_into_user_for_user(user, token)
      socket
    else
      socket
    end
  end

  defp maybe_merge_cart_token(socket, _session), do: socket
end
