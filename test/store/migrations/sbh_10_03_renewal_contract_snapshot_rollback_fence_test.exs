defmodule Store.Sbh1003FenceMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :store,
    adapter: Ecto.Adapters.Postgres
end

defmodule Store.Migrations.Sbh1003RenewalContractSnapshotRollbackFenceTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  alias Store.TestSupport.IsolatedMigrationDatabase
  alias Store.TestSupport.Sbh1003RollbackFenceSeed

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

  setup_all do
    context =
      IsolatedMigrationDatabase.start!("sbh_10_03_fence", Store.Sbh1003FenceMigrationTestRepo)

    on_exit(fn -> IsolatedMigrationDatabase.stop!(context) end)

    {:ok, context}
  end

  setup %{repo: repo} do
    ensure_sbh_1003_and_fence_up(repo)
    SQL.query!(repo, "DELETE FROM renewal_attempts", [])
    :ok
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
    Sbh1003RollbackFenceSeed.insert_durable_renewal_contract_evidence!(repo, @test_key_prefix)

    assert durable_renewal_contract_evidence?(repo)

    assert_raise Ecto.MigrationError, ~r/durable renewal contract evidence exists/, fn ->
      migrate_down(repo, @fence_version, @fence_migration)
    end

    assert charged_contract_snapshot_column?(repo)
    assert @fence_version in Migrator.migrated_versions(repo)
    assert @sbh_1003_version in Migrator.migrated_versions(repo)
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

  defp scalar(repo, query, params) do
    SQL.query!(repo, query, params).rows |> List.first() |> List.first()
  end
end
