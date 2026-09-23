defmodule Store.Subscriptions.Changes.OptimisticAggregateLock do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Resource.Change.OptimisticLock

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.changing_attributes?(changeset) do
      OptimisticLock.change(changeset, [attribute: :aggregate_version], context)
    else
      changeset
    end
  end
end
