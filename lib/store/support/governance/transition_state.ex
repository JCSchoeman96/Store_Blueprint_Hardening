defmodule Store.Support.Governance.TransitionState do
  @moduledoc """
  Transition helper that enforces replay NOOP semantics and stable invalid-transition errors.
  """

  use Ash.Resource.Change

  alias Ash.Resource.Change.OptimisticLock

  @invalid_transition_code "INVALID_STATE_TRANSITION"

  @impl true
  def change(changeset, opts, context) do
    state_attribute =
      if Keyword.has_key?(opts, :state_attribute), do: opts[:state_attribute], else: :state

    lock_attribute =
      if Keyword.has_key?(opts, :lock_attribute), do: opts[:lock_attribute], else: :version

    target = opts[:target]
    current = Map.get(changeset.data || %{}, state_attribute)

    cond do
      is_nil(target) ->
        Ash.Changeset.add_error(changeset,
          field: state_attribute,
          message: @invalid_transition_code
        )

      current == target ->
        changeset

      transition_allowed?(changeset, current, target) ->
        changeset
        |> AshStateMachine.transition_state(target)
        |> maybe_optimistic_lock(lock_attribute, context)

      true ->
        Ash.Changeset.add_error(changeset,
          field: state_attribute,
          message: @invalid_transition_code
        )
    end
  end

  defp transition_allowed?(changeset, current, target) do
    changeset.resource
    |> AshStateMachine.Info.state_machine_transitions(changeset.action.name)
    |> Enum.any?(fn transition ->
      from_matches?(transition.from, current) and to_matches?(transition.to, target)
    end)
  end

  defp from_matches?(from, state), do: value_matches?(from, state)
  defp to_matches?(to, state), do: value_matches?(to, state)

  defp value_matches?(values, value) do
    wrapped = List.wrap(values)
    :* in wrapped or value in wrapped
  end

  defp maybe_optimistic_lock(changeset, nil, _context), do: changeset
  defp maybe_optimistic_lock(changeset, false, _context), do: changeset

  defp maybe_optimistic_lock(changeset, lock_attribute, context),
    do: OptimisticLock.change(changeset, [attribute: lock_attribute], context)
end
