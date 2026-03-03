defmodule Store.Digital.Types.DownloadGrantStatus do
  @moduledoc """
  Lifecycle states for a customer download grant.
  """

  use Ash.Type.Enum, values: [:active, :revoked, :expired]
end
