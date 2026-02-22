defmodule Store.Admin.Changes.SanitizeAuditMeta do
  @moduledoc """
  Normalizes, scrubs, and caps audit metadata before persistence.
  """

  use Ash.Resource.Change

  alias Store.Admin.AuditMeta

  @impl true
  def change(changeset, _opts, _context) do
    meta =
      changeset
      |> Ash.Changeset.get_attribute(:meta)
      |> AuditMeta.sanitize()

    Ash.Changeset.change_attribute(changeset, :meta, meta)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
