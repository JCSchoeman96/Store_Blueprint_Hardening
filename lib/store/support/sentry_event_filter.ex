defmodule Store.Support.SentryEventFilter do
  @moduledoc """
  Filters high-volume operational noise from Sentry.
  """

  @behaviour Sentry.EventFilter

  @impl true
  def exclude_exception?(%Phoenix.Router.NoRouteError{}, _source), do: true

  def exclude_exception?(%Ecto.NoResultsError{}, _source), do: true

  def exclude_exception?(_exception, _source), do: false
end
