defmodule Store.Digital.Types.DigitalAssetStatus do
  @moduledoc """
  Lifecycle states for a digital asset record.
  """

  use Ash.Type.Enum, values: [:active, :archived]
end
