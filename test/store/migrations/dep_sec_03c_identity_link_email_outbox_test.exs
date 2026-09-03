defmodule Store.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end

defmodule Store.Migrations.DepSec03cIdentityLinkEmailOutboxTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260902123000_dep_sec_03c_identity_link_email_outbox.exs",
      __DIR__
    )
  )

  @migration Store.Repo.Migrations.DepSec03cIdentityLinkEmailOutbox
  @version 20_260_902_123_000
  @constraint "email_outboxes_template_kind_refund_coherence_check"
  @test_key_prefix "dep-sec-03e-migration:"

  setup do
    {:ok, repo_pid} = Store.MigrationTestRepo.start_link(migration_repo_config())
    Process.unlink(repo_pid)

    cleanup = fn ->
      delete_test_rows(Store.MigrationTestRepo)
      restore_current_constraint(Store.MigrationTestRepo)
      migrate_up(Store.MigrationTestRepo)
      delete_test_rows(Store.MigrationTestRepo)
      Supervisor.stop(repo_pid)
    end

    on_exit(cleanup)

    delete_test_rows(Store.MigrationTestRepo)
    restore_current_constraint(Store.MigrationTestRepo)
    migrate_up(Store.MigrationTestRepo)

    :ok
  end

  test "a no-row rollback restores the previous constraint and can migrate up again" do
    assert 0 ==
             scalar(
               Store.MigrationTestRepo,
               "SELECT count(*) FROM email_outboxes WHERE template_kind::text = $1",
               ["identity_link_confirmation"]
             )

    assert :ok = migrate_down(Store.MigrationTestRepo)

    old_definition = constraint_definition(Store.MigrationTestRepo)
    refute old_definition =~ "identity_link_confirmation"

    order_id = insert_order(Store.MigrationTestRepo)

    insert_outbox(Store.MigrationTestRepo, order_id, "order_receipt")

    assert 1 ==
             scalar(
               Store.MigrationTestRepo,
               "SELECT count(*) FROM email_outboxes WHERE idempotency_key LIKE $1",
               [@test_key_prefix <> "%"]
             )

    assert_raise Postgrex.Error, fn ->
      insert_outbox(Store.MigrationTestRepo, nil, "identity_link_confirmation")
    end

    assert enum_label_exists?(Store.MigrationTestRepo)
    assert :ok = migrate_up(Store.MigrationTestRepo)
    assert constraint_definition(Store.MigrationTestRepo) =~ "identity_link_confirmation"
  end

  test "a rollback with identity-link rows fails before changing the current constraint" do
    insert_outbox(Store.MigrationTestRepo, nil, "identity_link_confirmation")
    current_definition = constraint_definition(Store.MigrationTestRepo)

    assert_raise Ecto.MigrationError, ~r/identity-link EmailOutbox rows exist/, fn ->
      migrate_down(Store.MigrationTestRepo)
    end

    assert constraint_definition(Store.MigrationTestRepo) == current_definition

    assert 1 ==
             scalar(
               Store.MigrationTestRepo,
               "SELECT count(*) FROM email_outboxes WHERE idempotency_key LIKE $1",
               [@test_key_prefix <> "%"]
             )

    assert constraint_definition(Store.MigrationTestRepo) =~ "identity_link_confirmation"
    assert @version in Migrator.migrated_versions(Store.MigrationTestRepo)
  end

  defp migration_repo_config do
    Store.Repo.config()
    |> Keyword.drop([:pool])
    |> Keyword.merge(
      name: Store.MigrationTestRepo,
      pool: DBConnection.ConnectionPool,
      pool_size: 2
    )
  end

  defp migrate_up(repo) do
    case Migrator.up(repo, @version, @migration, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp migrate_down(repo), do: Migrator.down(repo, @version, @migration, log: false)

  defp delete_test_rows(repo) do
    SQL.query!(
      repo,
      "DELETE FROM email_outboxes WHERE idempotency_key LIKE $1",
      [@test_key_prefix <> "%"]
    )

    SQL.query!(
      repo,
      "DELETE FROM orders WHERE order_ref LIKE $1",
      [@test_key_prefix <> "%"]
    )
  end

  defp restore_current_constraint(repo) do
    case SQL.query!(
           repo,
           """
           SELECT 1
           FROM pg_constraint
           WHERE conrelid = 'email_outboxes'::regclass
             AND conname = $1
           """,
           [@constraint]
         ).rows do
      [] ->
        SQL.query!(
          repo,
          """
          ALTER TABLE email_outboxes
          ADD CONSTRAINT email_outboxes_template_kind_refund_coherence_check
          CHECK (
            (
              order_id IS NOT NULL
              AND refund_id IS NULL
              AND subscription_id IS NULL
              AND template_kind IN (
                'order_receipt'::email_template_kind,
                'payment_authentication_required'::email_template_kind
              )
            ) OR (
              order_id IS NOT NULL
              AND refund_id IS NOT NULL
              AND subscription_id IS NULL
              AND template_kind IN (
                'refund_requested'::email_template_kind,
                'refund_processed'::email_template_kind
              )
            ) OR (
              order_id IS NULL
              AND refund_id IS NULL
              AND subscription_id IS NOT NULL
              AND template_kind IN (
                'renewal_reminder'::email_template_kind,
                'access_ended'::email_template_kind
              )
            ) OR (
              order_id IS NULL
              AND refund_id IS NULL
              AND subscription_id IS NULL
              AND template_kind = 'identity_link_confirmation'::email_template_kind
            )
          )
          """,
          []
        )

      _ ->
        :ok
    end
  end

  defp constraint_definition(repo) do
    [[definition]] =
      SQL.query!(
        repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'email_outboxes'::regclass AND conname = $1",
        [@constraint]
      ).rows

    definition
  end

  defp enum_label_exists?(repo) do
    scalar(
      repo,
      """
      SELECT EXISTS (
        SELECT 1
        FROM pg_enum
        WHERE enumtypid = 'email_template_kind'::regtype
          AND enumlabel = 'identity_link_confirmation'
      )
      """,
      []
    )
  end

  defp insert_order(repo) do
    key = @test_key_prefix <> "order:" <> Integer.to_string(System.unique_integer([:positive]))

    [[order_id]] =
      SQL.query!(
        repo,
        "INSERT INTO orders (order_ref) VALUES ($1) RETURNING id",
        [key]
      ).rows

    order_id
  end

  defp insert_outbox(repo, order_id, template_kind) do
    key =
      @test_key_prefix <>
        template_kind <> ":" <> Integer.to_string(System.unique_integer([:positive]))

    SQL.query!(
      repo,
      """
      INSERT INTO email_outboxes (
        order_id,
        template_kind,
        to_email,
        idempotency_key,
        provider,
        template_assigns
      ) VALUES ($1, $2::email_template_kind, $3, $4, 'swoosh', $5::jsonb)
      """,
      [
        order_id,
        template_kind,
        "migration-test@example.com",
        key,
        ~s({"confirmation_url":"http://localhost/confirm","identity_provider":"Google"})
      ]
    )
  end

  defp scalar(repo, query, params) do
    SQL.query!(repo, query, params).rows |> List.first() |> List.first()
  end
end
