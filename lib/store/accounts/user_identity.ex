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

    attribute :uid, :string do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :access_token, :string do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end

    attribute :access_token_expires_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end

    attribute :refresh_token, :string do
      allow_nil?(true)
      public?(false)
      sensitive?(true)
    end
  end

  relationships do
    belongs_to :user, Store.Accounts.User do
      attribute_type(Ash.Type.UUIDv7)
      allow_nil?(false)
      public?(false)
      attribute_public?(false)
      attribute_writable?(true)
      domain(Store.Accounts)
    end
  end

  user_identity do
    user_resource(Store.Accounts.User)
  end

  actions do
    read(:read) do
      primary?(true)
      public?(false)
    end

    destroy(:destroy) do
      primary?(true)
      public?(false)
    end

    create(:upsert) do
      accept([:strategy])
      upsert?(true)
      upsert_identity(:unique_on_strategy_and_uid)
      upsert_fields([:access_token, :access_token_expires_at, :refresh_token])
      public?(false)

      argument(:user_info, :map, allow_nil?: false)
      argument(:oauth_tokens, :map, allow_nil?: false)
      argument(:user_id, Ash.Type.UUIDv7, allow_nil?: false)

      change(AshAuthentication.UserIdentity.UpsertIdentityChange)
    end
  end

  postgres do
    table("user_identities")
    repo(Store.Repo)

    references do
      reference(:user, on_delete: :delete)
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy always() do
      forbid_if(always())
    end
  end
end
