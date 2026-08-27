defmodule Store.Accounts.UserIdentity do
  @moduledoc """
  Durable provider identity associated with an accounts user.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.UserIdentity],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Accounts

  attributes do
    uuid_v7_primary_key(:id)
  end

  user_identity do
    user_resource(Store.Accounts.User)
  end

  postgres do
    table("user_identities")
    repo(Store.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end
  end
end
