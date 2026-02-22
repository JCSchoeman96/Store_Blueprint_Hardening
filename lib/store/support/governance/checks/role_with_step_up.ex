defmodule Store.Support.Governance.Checks.RoleWithStepUp do
  @moduledoc """
  Policy check requiring both role membership and recent step-up proof.
  """

  use Ash.Policy.SimpleCheck

  alias Store.Admin.Authorization
  alias Store.Support.Governance.Checks.StepUpRecent

  @impl true
  def describe(opts) do
    roles = List.wrap(opts[:roles])
    window_minutes = opts[:window_minutes] || 15

    "actor has one of roles #{inspect(roles)} and step_up_at_mono_usec is within #{window_minutes} minutes"
  end

  @impl true
  def match?(actor, context, opts) do
    roles = List.wrap(opts[:roles])
    window_minutes = opts[:window_minutes] || 15

    has_role? = Authorization.has_any_role?(actor, roles)

    step_up? = StepUpRecent.match?(actor, context, window_minutes: window_minutes)

    has_role? and step_up?
  end
end
