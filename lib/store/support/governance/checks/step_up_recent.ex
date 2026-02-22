defmodule Store.Support.Governance.Checks.StepUpRecent do
  @moduledoc """
  Policy check enforcing recent step-up proof from action/query context.
  """

  use Ash.Policy.SimpleCheck

  @default_window_minutes 15

  @impl true
  def describe(opts) do
    window_minutes = opts[:window_minutes] || @default_window_minutes
    "step_up_at is present and within #{window_minutes} minutes"
  end

  @impl true
  def match?(_actor, context, opts) do
    window_minutes = opts[:window_minutes] || @default_window_minutes

    context
    |> extract_step_up_at()
    |> parse_step_up_at()
    |> within_window?(window_minutes)
  end

  defp extract_step_up_at(context) when is_map(context) do
    subject_context = nested_context(context, :subject)
    changeset_context = nested_context(context, :changeset)
    query_context = nested_context(context, :query)
    direct_context = as_map(Map.get(context, :context))

    Map.get(subject_context, :step_up_at) ||
      Map.get(context, :step_up_at) ||
      Map.get(changeset_context, :step_up_at) ||
      Map.get(query_context, :step_up_at) ||
      Map.get(direct_context, :step_up_at)
  end

  defp extract_step_up_at(_), do: nil

  defp parse_step_up_at(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_step_up_at(step_up_at) when is_binary(step_up_at) do
    DateTime.from_iso8601(step_up_at)
  end

  defp parse_step_up_at(_), do: :error

  defp within_window?({:ok, %DateTime{} = step_up_at}, window_minutes) do
    window_seconds = window_minutes * 60
    delta = DateTime.diff(DateTime.utc_now(), step_up_at, :second)
    delta >= 0 and delta <= window_seconds
  end

  defp within_window?(_, _window_minutes), do: false

  defp nested_context(context, key) do
    context
    |> Map.get(key)
    |> as_map()
    |> Map.get(:context)
    |> as_map()
  end

  defp as_map(%{} = value), do: value
  defp as_map(_), do: %{}
end
