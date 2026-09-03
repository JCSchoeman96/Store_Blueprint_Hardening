defmodule Store.Accounts.User do
  @moduledoc """
  User resource for password and Google OAuth authentication.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Accounts

  attributes do
    uuid_v7_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
      sensitive?(true)
    end

    attribute :hashed_password, :string do
      allow_nil?(true)
      sensitive?(true)
    end

    attribute :confirmed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_email, [:email])
  end

  actions do
    defaults([:read])

    read :get_by_subject do
      description("Load a user by JWT subject")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    create :register_with_google do
      description("Register or sign in with Google OAuth2")
      argument(:user_info, :map, allow_nil?: false)
      argument(:oauth_tokens, :map, allow_nil?: false)

      upsert?(true)
      upsert_identity(:unique_email)
      upsert_fields([])

      change(AshAuthentication.Strategy.OAuth2.IdentityChange)
      change(AshAuthentication.GenerateTokenChange)

      change(fn changeset, _context ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        changeset
        |> Ash.Changeset.change_attribute(:email, user_info["email"])
        |> Ash.Changeset.change_attribute(:confirmed_at, DateTime.utc_now())
      end)
    end
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(Store.Accounts.Token)
      require_token_presence_for_authentication?(true)

      signing_secret(fn _, _ ->
        Application.fetch_env(:store, :token_signing_secret)
      end)

      store_all_tokens?(true)
    end

    strategies do
      password :password do
        identity_field(:email)
        hashed_password_field(:hashed_password)

        resettable do
          sender(Store.Accounts.User.Senders.SendPasswordResetEmail)
        end
      end

      google :google do
        client_id(Store.Accounts.Secrets)
        client_secret(Store.Accounts.Secrets)
        redirect_uri(Store.Accounts.Secrets)
        register_action_name(:register_with_google)
        identity_resource(Store.Accounts.UserIdentity)
        trust_email_verified?(false)
        on_untrusted_email_match(:confirm)
      end
    end

    add_ons do
      confirmation :confirm_new_user do
        monitor_fields([:email])
        confirm_on_create?(true)
        confirm_on_update?(false)
        require_interaction?(true)
        sender(Store.Accounts.User.Senders.SendNewUserConfirmationEmail)
        confirmed_at_field(:confirmed_at)
      end
    end
  end

  postgres do
    table("users")
    repo(Store.Repo)
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if(always())
    end

    policy action_type(:read) do
      authorize_if(expr(id == ^actor(:id)))
    end
  end
end
