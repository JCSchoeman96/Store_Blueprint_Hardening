defmodule Store.Admin.Types.Role do
  @moduledoc """
  Pinned admin role enum.
  """

  use Ash.Type.Enum,
    values: [:super_admin, :admin, :editor, :support, :customer]
end
