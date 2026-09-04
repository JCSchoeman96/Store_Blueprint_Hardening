defmodule Store.Accounts.OAuthIdentityLinkingTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  import Swoosh.TestAssertions
  require Ash.Query

  alias AshAuthentication.AddOn.Confirmation
  alias AshAuthentication.Errors.{AuthenticationFailed, ConfirmationRequired}
  alias AshAuthentication.{Info, Jwt, Strategy}
  alias Store.Accounts.User
  alias Store.Accounts.User.Senders.SendNewUserConfirmationEmail, as: ConfirmationSender
  alias Store.Comms.EmailOutbox
  alias Store.Support.ID.UUIDv7
  alias Store.Workers.DeliverEmailOutboxWorker

  setup :set_swoosh_global

  test "Google strategy uses durable identities and rejects missing provider UIDs" do
    google = Info.strategy!(User, :google)

    assert google.identity_resource == Store.Accounts.UserIdentity
    assert google.trust_email_verified? == false
    assert google.on_untrusted_email_match == :confirm

    email = unique_email("missing-uid")

    assert {:error, %AuthenticationFailed{}} =
             Strategy.action(
               google,
               :register,
               %{
                 "user_info" => %{"email" => email, "email_verified" => true},
                 "oauth_tokens" => %{"access_token" => "not-persisted"}
               },
               []
             )

    assert user_count(email) == 0
    assert identity_count("missing-uid") == 0
  end

  test "a new Google user gets exactly one durable identity" do
    email = unique_email("new-google")
    uid = unique_uid("new")

    assert {:ok, user} = register_with_google(email, uid)
    assert identity_count(uid) == 1
    assert identity_owner(uid) == user.id
    assert user_count(email) == 1
  end

  test "a known Google UID resolves to its owner without duplicates" do
    uid = unique_uid("known")
    first_email = unique_email("known-first")
    second_email = unique_email("known-second")

    assert {:ok, first_user} = register_with_google(first_email, uid)
    assert {:ok, second_result} = register_with_google(second_email, uid)

    assert second_result.id == first_user.id
    assert identity_count(uid) == 1
    assert user_count(first_email) == 1
    assert user_count(second_email) == 0
  end

  test "an existing email match requires confirmation and stores no identity first" do
    email = unique_email("historical")
    user = insert_historical_user!(email)
    uid = unique_uid("pending")
    oauth_token = "must-stay-server-side"

    assert {:error, %AuthenticationFailed{caused_by: %ConfirmationRequired{}}} =
             register_with_google(email, uid, oauth_token)

    assert identity_count(uid) == 0
    assert user_count(email) == 1
    assert identity_email_was_enqueued?(email, oauth_token)
    refute_email_sent()
    assert user.id == load_user!(email).id
  end

  test "valid native identity-link confirmation creates one identity" do
    user = insert_historical_user!(unique_email("confirm-link"))
    uid = unique_uid("confirmed")
    token = identity_link_token(user, uid)

    assert identity_count(uid) == 0
    assert {:ok, confirmed_user} = confirm(token)
    assert confirmed_user.id == user.id
    assert identity_count(uid) == 1
    assert identity_owner(uid) == user.id

    assert {:error, _} = confirm(token)
    assert identity_count(uid) == 1
  end

  test "expired and invalid confirmations create no identity" do
    user = insert_historical_user!(unique_email("expired-link"))
    expired_uid = unique_uid("expired")
    invalid_uid = unique_uid("invalid")
    confirmation = Info.strategy!(User, :confirm_new_user)

    {:ok, expired_token, _claims} =
      Jwt.token_for_user(user, %{"act" => confirmation.confirm_action_name}, token_lifetime: -1)

    assert :ok =
             Confirmation.Actions.store_identity_link(
               confirmation,
               expired_token,
               identity_payload(expired_uid),
               []
             )

    assert {:error, _} = confirm(expired_token)
    assert {:error, _} = confirm("not-a-confirmation-token")
    assert identity_count(expired_uid) == 0
    assert identity_count(invalid_uid) == 0
  end

  test "cross-user and client-controlled values cannot change the stored link target" do
    first_user = insert_historical_user!(unique_email("link-owner"))
    second_user = insert_historical_user!(unique_email("other-user"))
    uid = unique_uid("bound")
    token = identity_link_token(first_user, uid)

    assert {:error, %Ash.Error.Invalid{}} =
             Strategy.action(
               Info.strategy!(User, :confirm_new_user),
               :confirm,
               %{
                 "confirm" => token,
                 "user_id" => second_user.id,
                 "user_info" => %{"sub" => unique_uid("forged")},
                 "oauth_tokens" => %{"access_token" => "forged"}
               },
               []
             )

    assert identity_count(uid) == 0

    assert {:ok, confirmed_user} = confirm(token)
    assert confirmed_user.id == first_user.id
    assert identity_count(uid) == 1
    assert identity_owner(uid) == first_user.id
    assert identity_count("forged") == 0
  end

  test "a conflicting provider UID cannot be reassigned during confirmation" do
    first_user = insert_historical_user!(unique_email("conflict-first"))
    second_user = insert_historical_user!(unique_email("conflict-second"))
    uid = unique_uid("conflicting")
    insert_identity!(second_user.id, uid)
    token = identity_link_token(first_user, uid)

    assert {:ok, confirmed_user} = confirm(token)
    assert confirmed_user.id == first_user.id
    assert identity_count(uid) == 1
    assert identity_owner(uid) == second_user.id
  end

  test "identity-link sender enqueues durable delivery without synchronous mail" do
    user = insert_historical_user!(unique_email("sender"))
    token = identity_link_token(user, unique_uid("sender"))
    email = to_string(user.email)
    assert {:ok, %{"jti" => jti}, _resource} = AshAuthentication.Jwt.verify(token, User)

    assert :ok =
             ConfirmationSender.send(
               user,
               token,
               confirmation_type: :identity_link,
               provider: :google
             )

    refute_email_sent()

    assert {:ok, [outbox]} =
             EmailOutbox
             |> Ash.Query.filter(
               expr(to_email == ^email and template_kind == :identity_link_confirmation)
             )
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    assert outbox.order_id == nil
    assert outbox.refund_id == nil
    assert outbox.subscription_id == nil
    assert outbox.provider == :swoosh
    assert outbox.template_kind == :identity_link_confirmation
    assert outbox.body_text == ""
    assert outbox.body_html == nil
    assert outbox.template_assigns["identity_provider"] == "Google"
    assert outbox.template_assigns["confirmation_url"] =~ token
    assert outbox.idempotency_key == "identity_link_confirmation:google:#{jti}"

    assert Map.keys(outbox.template_assigns) |> Enum.sort() == [
             "confirmation_url",
             "identity_provider"
           ]

    refute outbox.idempotency_key =~ token
    refute inspect(outbox.template_assigns) =~ "oauth-secret"

    assert [%{args: args} = job] =
             all_enqueued(worker: DeliverEmailOutboxWorker)

    assert job.args == %{"email_outbox_id" => outbox.id}
    assert Map.keys(args) == ["email_outbox_id"]
    refute inspect(args) =~ token
    refute inspect(args) =~ "oauth-secret"
  end

  test "repeated identity-link sender calls share one outbox and delivery job by JTI" do
    user = insert_historical_user!(unique_email("duplicate-sender"))
    token = identity_link_token(user, unique_uid("duplicate-sender"))
    email = to_string(user.email)

    assert :ok =
             ConfirmationSender.send(
               user,
               token,
               confirmation_type: :identity_link,
               provider: :google
             )

    assert :ok =
             ConfirmationSender.send(
               user,
               token,
               confirmation_type: :identity_link,
               provider: :google
             )

    assert {:ok, outboxes} =
             EmailOutbox
             |> Ash.Query.filter(expr(to_email == ^email))
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    identity_outboxes = Enum.filter(outboxes, &(&1.template_kind == :identity_link_confirmation))
    assert [%{idempotency_key: key}] = identity_outboxes
    assert key =~ "identity_link_confirmation:google:"
    assert length(all_enqueued(worker: DeliverEmailOutboxWorker)) == 1
  end

  test "different identity-link confirmation JTIs create different outbox identities" do
    user = insert_historical_user!(unique_email("distinct-sender"))
    first_token = identity_link_token(user, unique_uid("distinct-first"))
    second_token = identity_link_token(user, unique_uid("distinct-second"))
    email = to_string(user.email)

    assert :ok =
             ConfirmationSender.send(
               user,
               first_token,
               confirmation_type: :identity_link,
               provider: :google
             )

    assert :ok =
             ConfirmationSender.send(
               user,
               second_token,
               confirmation_type: :identity_link,
               provider: :google
             )

    assert {:ok, outboxes} =
             EmailOutbox
             |> Ash.Query.filter(expr(to_email == ^email))
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    identity_outboxes = Enum.filter(outboxes, &(&1.template_kind == :identity_link_confirmation))
    assert length(identity_outboxes) == 2
    assert identity_outboxes |> Enum.map(& &1.idempotency_key) |> Enum.uniq() |> length() == 2
    refute Enum.any?(identity_outboxes, &(&1.idempotency_key =~ first_token))
    refute Enum.any?(identity_outboxes, &(&1.idempotency_key =~ second_token))
    assert length(all_enqueued(worker: DeliverEmailOutboxWorker)) == 2
  end

  test "identity-link worker delivers provider-specific copy without OAuth payloads" do
    user = insert_historical_user!(unique_email("delivery"))
    token = identity_link_token(user, unique_uid("delivery"))

    assert :ok =
             ConfirmationSender.send(
               user,
               token,
               confirmation_type: :identity_link,
               provider: :google
             )

    refute_email_sent()
    outbox = fetch_identity_outbox!(to_string(user.email))

    assert :ok = perform_job(DeliverEmailOutboxWorker, %{"email_outbox_id" => outbox.id})

    assert_email_sent(fn email ->
      email.subject == "Confirm linking your google login" and
        email.html_body =~ "Google" and
        email.html_body =~ "access to your account" and
        email.html_body =~ token and
        not (email.html_body =~ "oauth-secret") and
        not (email.text_body =~ "oauth-secret")
    end)
  end

  test "identity-link sender returns enqueue validation errors without sending mail" do
    user = insert_historical_user!(unique_email("sender-error"))

    assert {:error, :invalid_confirmation_token} =
             ConfirmationSender.send(
               user,
               "not-a-confirmation-token",
               confirmation_type: :identity_link,
               provider: :google
             )

    refute_email_sent()
  end

  defp register_with_google(email, uid, access_token \\ "test-access-token") do
    Strategy.action(
      Info.strategy!(User, :google),
      :register,
      %{
        "user_info" => %{
          "sub" => uid,
          "email" => email,
          "email_verified" => true
        },
        "oauth_tokens" => %{"access_token" => access_token}
      },
      []
    )
  end

  defp identity_link_token(user, uid) do
    {:ok, token} =
      Confirmation.confirmation_token_for_link(
        Info.strategy!(User, :confirm_new_user),
        user,
        identity_payload(uid),
        []
      )

    token
  end

  defp identity_payload(uid) do
    %{
      "strategy" => "google",
      "user_info" => %{
        "sub" => uid,
        "email" => "provider@example.com",
        "email_verified" => true
      },
      "oauth_tokens" => %{"access_token" => "oauth-secret"}
    }
  end

  defp confirm(token) do
    Strategy.action(
      Info.strategy!(User, :confirm_new_user),
      :confirm,
      %{"confirm" => token},
      []
    )
  end

  defp insert_historical_user!(email) do
    id = UUIDv7.bingenerate()

    Repo.query!(
      "INSERT INTO users (id, email, confirmed_at) VALUES ($1, $2, $3)",
      [id, email, DateTime.utc_now()]
    )

    load_user!(email)
  end

  defp insert_identity!(user_id, uid) do
    Repo.query!(
      "INSERT INTO user_identities (id, strategy, uid, user_id) VALUES ($1, $2, $3, $4)",
      [UUIDv7.bingenerate(), "google", uid, UUIDv7.decode!(user_id)]
    )
  end

  defp load_user!(email) do
    Repo.query!("SELECT id FROM users WHERE email = $1", [email]).rows
    |> case do
      [[id]] -> Ash.get!(User, UUIDv7.encode!(id), domain: Store.Accounts, authorize?: false)
    end
  end

  defp user_count(email), do: scalar("SELECT count(*) FROM users WHERE email = $1", [email])

  defp identity_count(uid),
    do:
      scalar("SELECT count(*) FROM user_identities WHERE strategy = 'google' AND uid = $1", [uid])

  defp identity_owner(uid) do
    [[id]] =
      Repo.query!("SELECT user_id FROM user_identities WHERE strategy = 'google' AND uid = $1", [
        uid
      ]).rows

    UUIDv7.encode!(id)
  end

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> List.first() |> List.first()

  defp identity_email_was_enqueued?(email, oauth_token) do
    outbox = fetch_identity_outbox!(email)

    outbox.subject == "Confirm linking your google login" and
      outbox.template_assigns["confirmation_url"] =~ "/confirm-new-user/" and
      not (outbox.template_assigns["confirmation_url"] =~ oauth_token) and
      not (Map.values(outbox.template_assigns) |> Enum.any?(&(&1 == "oauth-secret")))
  end

  defp fetch_identity_outbox!(email) do
    assert {:ok, [outbox]} =
             EmailOutbox
             |> Ash.Query.filter(
               expr(to_email == ^email and template_kind == :identity_link_confirmation)
             )
             |> Ash.read(domain: Store.Comms, authorize?: false, context: %{system?: true})

    outbox
  end

  defp unique_email(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}@example.com"
  defp unique_uid(prefix), do: "#{prefix}-uid-#{System.unique_integer([:positive])}"
end
