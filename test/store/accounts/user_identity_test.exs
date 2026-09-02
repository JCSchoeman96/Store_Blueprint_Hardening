defmodule Store.Accounts.UserIdentityTest do
  use Store.DataCase, async: false

  alias Ash.Resource.Info
  alias AshAuthentication.UserIdentity.Actions, as: UserIdentityActions
  alias AshAuthentication.UserIdentity.Info, as: UserIdentityInfo
  alias Store.Accounts.UserIdentity
  alias Store.Support.ID.UUIDv7

  import Store.TestFixtures, only: [unique_email: 1]

  test "registers the persistent identity resource in the Accounts domain" do
    assert_identity_resource_loaded()

    assert UserIdentity in Ash.Domain.Info.resources(Store.Accounts)

    assert {:ok, Store.Accounts.User} ==
             UserIdentityInfo.user_identity_user_resource(UserIdentity)

    assert AshPostgres.DataLayer.Info.table(UserIdentity) == "user_identities"
    assert AshPostgres.DataLayer.Info.repo(UserIdentity) == Store.Repo
  end

  test "uses UUIDv7 ownership metadata and the extension provider identity" do
    assert_identity_resource_loaded()

    assert %{type: Ash.Type.UUIDv7, primary_key?: true, allow_nil?: false} =
             Info.attribute(UserIdentity, :id)

    assert %{keys: [:strategy, :uid], name: :unique_on_strategy_and_uid} =
             Enum.find(Info.identities(UserIdentity), &(&1.keys == [:strategy, :uid]))

    for field <- [:strategy, :uid, :user_id] do
      assert %{allow_nil?: false} = Info.attribute(UserIdentity, field)
    end

    assert %{public?: true} = Info.attribute(UserIdentity, :strategy)
    assert %{public?: false} = Info.attribute(UserIdentity, :uid)

    assert %{allow_nil?: false, destination: Store.Accounts.User} =
             Info.relationship(UserIdentity, :user)
  end

  test "protects provider tokens and exposes no public CRUD actions" do
    assert_identity_resource_loaded()

    for field <- [:access_token, :access_token_expires_at, :refresh_token] do
      assert %{public?: false, sensitive?: true} = Info.attribute(UserIdentity, field)
    end

    assert Info.public_actions(UserIdentity) == []
  end

  test "allows only the trusted AshAuthentication policy path" do
    assert_identity_resource_loaded()

    policies = Ash.Policy.Info.policies(UserIdentity)

    assert Enum.any?(policies, fn policy ->
             policy.bypass? == true and
               Enum.any?(policy.policies, fn check ->
                 check.type == :authorize_if and
                   check.check_module == Ash.Policy.Check.Static and
                   check.check_opts[:result] == true
               end)
           end)

    assert Enum.any?(policies, fn policy ->
             Enum.any?(policy.policies, fn check ->
               check.type == :forbid_if and
                 check.check_module == Ash.Policy.Check.Static and
                 check.check_opts[:result] == true
             end)
           end)
  end

  test "database constraints protect ownership and delete identities with their user" do
    assert_identity_resource_loaded()

    assert [["NO"]] =
             Repo.query!(
               "SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'user_identities' AND column_name = 'user_id'",
               []
             ).rows

    assert [[definition]] =
             Repo.query!(
               "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'user_identities_user_id_fkey'",
               []
             ).rows

    assert definition =~ "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"

    assert [[true]] =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'user_identities' AND indexname = 'user_identities_unique_on_strategy_and_uid_index')",
               []
             ).rows

    user_id = insert_user!()
    identity_id = insert_identity!(user_id, "cascade-uid")

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "INSERT INTO user_identities (id, strategy, uid, user_id) VALUES ($1, $2, $3, $4)",
        [UUIDv7.bingenerate(), "google", "cascade-uid", user_id]
      )
    end

    Repo.query!("DELETE FROM users WHERE id = $1", [user_id])

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM user_identities WHERE id = $1", [identity_id]).rows
  end

  test "identity upsert cannot reassign an existing provider identity" do
    assert_identity_resource_loaded()

    first_user_id = insert_user!()
    second_user_id = insert_user!()

    assert {:ok, identity} =
             UserIdentityActions.upsert(
               UserIdentity,
               %{
                 strategy: "google",
                 user_info: %{"sub" => "owner-uid"},
                 oauth_tokens: %{"access_token" => "first-token"},
                 user_id: first_user_id
               }
             )

    assert {:ok, same_identity} =
             UserIdentityActions.upsert(
               UserIdentity,
               %{
                 strategy: "google",
                 user_info: %{"sub" => "owner-uid"},
                 oauth_tokens: %{"access_token" => "second-token"},
                 user_id: second_user_id
               }
             )

    assert same_identity.id == identity.id

    assert [[^first_user_id]] =
             Repo.query!(
               "SELECT user_id FROM user_identities WHERE strategy = 'google' AND uid = 'owner-uid'",
               []
             ).rows
  end

  defp assert_identity_resource_loaded do
    assert Code.ensure_loaded?(UserIdentity)
  end

  defp insert_user! do
    user_id = UUIDv7.bingenerate()

    Repo.query!(
      "INSERT INTO users (id, email) VALUES ($1, $2)",
      [user_id, unique_email("identity")]
    )

    user_id
  end

  defp insert_identity!(user_id, uid) do
    identity_id = UUIDv7.bingenerate()

    Repo.query!(
      "INSERT INTO user_identities (id, strategy, uid, user_id) VALUES ($1, $2, $3, $4)",
      [identity_id, "google", uid, user_id]
    )

    identity_id
  end
end
