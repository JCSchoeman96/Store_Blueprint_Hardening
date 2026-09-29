defmodule Store.Sbh1003FenceMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end

defmodule Store.Migrations.Sbh1003RenewalContractSnapshotRollbackFenceTest do
  use ExUnit.Case, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  alias Store.Subscriptions.{Facade, RenewalAttempt}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260924203729_sbh_10_03_renewal_contract_snapshot.exs",
      __DIR__
    )
  )

  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260929101700_sbh_10_03_renewal_contract_snapshot_rollback_fence.exs",
      __DIR__
    )
  )

  @sbh_1003_version 20_260_924_203_729
  @sbh_1003_migration Store.Repo.Migrations.Sbh1003RenewalContractSnapshot
  @fence_version 20_260_929_101_700
  @fence_migration Store.Repo.Migrations.Sbh1003RenewalContractSnapshotRollbackFence
  @test_key_prefix "sbh-10-03-fence-migration:"

  setup context do
    StripeAPIStub.setup_default(context)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Store.Repo, sandbox: false)
    ensure_subscription_fixture!()

    {:ok, repo_pid} = start_fence_migration_test_repo!()
    Process.unlink(repo_pid)

    cleanup = fn ->
      delete_test_renewal_attempts(Store.Sbh1003FenceMigrationTestRepo)
      ensure_sbh_1003_and_fence_up(Store.Sbh1003FenceMigrationTestRepo)
      Supervisor.stop(repo_pid, :normal)
    end

    on_exit(cleanup)

    delete_test_renewal_attempts(Store.Sbh1003FenceMigrationTestRepo)
    ensure_sbh_1003_and_fence_up(Store.Sbh1003FenceMigrationTestRepo)

    {:ok, repo: Store.Sbh1003FenceMigrationTestRepo}
  end

  test "a no-evidence rollback crosses the fence and can roll back SBH-10-03", %{repo: repo} do
    refute durable_renewal_contract_evidence?(repo)

    assert :ok = migrate_down(repo, @fence_version, @fence_migration)
    refute @fence_version in Migrator.migrated_versions(repo)
    assert charged_contract_snapshot_column?(repo)

    assert :ok = migrate_down(repo, @sbh_1003_version, @sbh_1003_migration)
    refute charged_contract_snapshot_column?(repo)

    assert :ok = migrate_up(repo, @sbh_1003_version, @sbh_1003_migration)
    assert :ok = migrate_up(repo, @fence_version, @fence_migration)
    assert charged_contract_snapshot_column?(repo)
    assert @fence_version in Migrator.migrated_versions(repo)
  end

  test "a rollback with durable renewal-contract evidence is blocked before SBH-10-03 mutation",
       %{repo: repo} do
    insert_durable_renewal_contract_evidence!(repo)

    assert durable_renewal_contract_evidence?(repo)

    assert_raise Ecto.MigrationError, ~r/durable renewal contract evidence exists/, fn ->
      migrate_down(repo, @fence_version, @fence_migration)
    end

    assert charged_contract_snapshot_column?(repo)
    assert @fence_version in Migrator.migrated_versions(repo)
    assert @sbh_1003_version in Migrator.migrated_versions(repo)
  end

  defp ensure_subscription_fixture! do
    if subscription_fixture_available?() do
      :ok
    else
      customer = SubscriptionsFixtures.create_customer!(@test_key_prefix <> "subscription")
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
      plan = SubscriptionsFixtures.create_subscription_plan!()
      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
      SubscriptionsFixtures.create_plan_revision!(plan)

      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
      :ok
    end
  end

  defp subscription_fixture_available? do
    %{rows: [[count]]} =
      Store.Repo.query!(
        "SELECT count(*)::bigint FROM subscriptions WHERE current_plan_revision_id IS NOT NULL",
        []
      )

    count > 0
  end

  defp start_fence_migration_test_repo! do
    case Store.Sbh1003FenceMigrationTestRepo.start_link(migration_repo_config()) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp migration_repo_config do
    Store.Repo.config()
    |> Keyword.drop([:pool])
    |> Keyword.merge(
      name: Store.Sbh1003FenceMigrationTestRepo,
      pool: DBConnection.ConnectionPool,
      pool_size: 2
    )
  end

  defp ensure_sbh_1003_and_fence_up(repo) do
    migrate_up(repo, @sbh_1003_version, @sbh_1003_migration)
    migrate_up(repo, @fence_version, @fence_migration)
  end

  defp migrate_up(repo, version, migration) do
    case Migrator.up(repo, version, migration, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp migrate_down(repo, version, migration),
    do: Migrator.down(repo, version, migration, log: false)

  defp delete_test_renewal_attempts(repo) do
    SQL.query!(
      repo,
      "DELETE FROM renewal_attempts WHERE renewal_key LIKE $1",
      [@test_key_prefix <> "%"]
    )
  end

  defp durable_renewal_contract_evidence?(repo) do
    scalar(
      repo,
      """
      SELECT EXISTS (
        SELECT 1
        FROM renewal_attempts
        WHERE charged_contract_version IS NOT NULL
           OR plan_revision_id IS NOT NULL
           OR variant_id IS NOT NULL
           OR quantity IS NOT NULL
           OR amount_minor IS NOT NULL
           OR currency IS NOT NULL
           OR contract_change_id IS NOT NULL
           OR expected_subscription_version IS NOT NULL
           OR charged_contract_snapshot IS NOT NULL
      )
      """,
      []
    )
  end

  defp charged_contract_snapshot_column?(repo) do
    scalar(
      repo,
      """
      SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'renewal_attempts'
          AND column_name = 'charged_contract_snapshot'
      )
      """,
      []
    )
  end

  defp insert_durable_renewal_contract_evidence!(repo) do
    token = @test_key_prefix <> Integer.to_string(System.unique_integer([:positive]))
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        amount_minor: 1_300,
        currency: "USD"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    SubscriptionsFixtures.create_plan_revision!(plan)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -86_410, :second),
        provider_billing_ref: "pm_#{token}",
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(StripeAPIStub.payment_intent_response(params)))
    end)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    attempt =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    SQL.query!(
      repo,
      "UPDATE renewal_attempts SET renewal_key = $2 WHERE id = $1",
      [Ecto.UUID.dump!(attempt.id), token <> ":attempt"]
    )

    assert attempt.charged_contract_version == 1
    assert is_map(attempt.charged_contract_snapshot)
  end

  defp scalar(repo, query, params) do
    SQL.query!(repo, query, params).rows |> List.first() |> List.first()
  end
end
