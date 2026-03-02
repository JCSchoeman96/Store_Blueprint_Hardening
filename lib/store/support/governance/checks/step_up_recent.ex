defmodule Store.Support.Governance.Checks.StepUpRecent do
  @moduledoc """
  Policy check enforcing recent step-up proof from action/query context.
  """

  use Ash.Policy.SimpleCheck

  alias Store.Support.Time

  @default_window_minutes 15

  @impl true
  def describe(opts) do
    window_minutes = opts[:window_minutes] || @default_window_minutes
    "step_up_at_mono_usec is present and within #{window_minutes} minutes"
  end

  @impl true
  def match?(_actor, context, opts) do
    window_minutes = opts[:window_minutes] || @default_window_minutes
    window_usec = Time.minutes_to_usec(window_minutes)

    context
    |> extract_step_up_at_mono_usec()
    |> parse_step_up_at_mono_usec()
    |> within_window?(window_usec)
  end

  defp extract_step_up_at_mono_usec(context) when is_map(context) do
    subject_context = nested_context(context, :subject)
    changeset_context = nested_context(context, :changeset)
    query_context = nested_context(context, :query)
    direct_context = as_map(get_key(context, :context))

    get_key(subject_context, :step_up_at_mono_usec) ||
      get_key(context, :step_up_at_mono_usec) ||
      get_key(changeset_context, :step_up_at_mono_usec) ||
      get_key(query_context, :step_up_at_mono_usec) ||
      get_key(direct_context, :step_up_at_mono_usec)
  end

  defp extract_step_up_at_mono_usec(_), do: nil

  defp parse_step_up_at_mono_usec(step_up_at_mono_usec)
       when is_integer(step_up_at_mono_usec),
       do: {:ok, step_up_at_mono_usec}

  defp parse_step_up_at_mono_usec(step_up_at_mono_usec) when is_binary(step_up_at_mono_usec) do
    case Integer.parse(step_up_at_mono_usec) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_step_up_at_mono_usec(_), do: :error

  defp within_window?({:ok, step_up_at_mono_usec}, window_usec),
    do: Time.within_window_usec?(step_up_at_mono_usec, window_usec)

  defp within_window?(_, _window_usec), do: false

  defp nested_context(context, key) do
    context
    |> get_key(key)
    |> as_map()
    |> get_key(:context)
    |> as_map()
  end

  defp get_key(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_key(_map, _key), do: nil

  defp as_map(%{} = value), do: value
  defp as_map(_), do: %{}
end
