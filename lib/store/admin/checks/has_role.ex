defmodule Store.Admin.Checks.HasRole do
  @moduledoc """
  Policy check requiring the actor to have at least one specified role.
  """

  use Ash.Policy.SimpleCheck

  alias Store.Admin.Authorization

  @impl true
  def describe(opts) do
    "actor has one of roles #{inspect(List.wrap(opts[:roles]))}"
  end

  @impl true
  def match?(actor, _context, opts) do
    Authorization.has_any_role?(actor, List.wrap(opts[:roles]))
  end
end
