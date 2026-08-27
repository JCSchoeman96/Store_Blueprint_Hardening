defmodule Store.Accounts do
  @moduledoc """
  Accounts domain for authentication and actor identity.
  """

  use Ash.Domain

  resources do
    resource(Store.Accounts.User)
    resource(Store.Accounts.UserIdentity)
    resource(Store.Accounts.Token)
  end
end
