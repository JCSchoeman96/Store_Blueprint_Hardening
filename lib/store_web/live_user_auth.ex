defmodule StoreWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use StoreWeb, :verified_routes
  alias AshAuthentication.Phoenix.LiveSession

  def on_mount(:current_user, _params, session, socket) do
    socket =
      socket
      |> LiveSession.assign_new_resources(session)
      |> put_step_up_assign(session)

    {:cont, socket}
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    socket = put_step_up_assign(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket = put_step_up_assign(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket = put_step_up_assign(socket, session)

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
end
