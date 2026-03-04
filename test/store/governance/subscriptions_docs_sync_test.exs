defmodule Store.Governance.SubscriptionsDocsSyncTest do
  use ExUnit.Case, async: false

  @task "check.subscriptions_docs_sync"
  @tmp_policy_file "tmp/subscriptions_docs_sync_policy_matrix_test.md"
  @tmp_route_file "tmp/subscriptions_docs_sync_route_inventory_test.md"
  @tmp_phase_file "tmp/subscriptions_docs_sync_phase_note_test.md"

  test "mix check aliases include subscriptions docs sync gate" do
    check_alias = Mix.Project.config()[:aliases][:check]
    check_static_alias = Mix.Project.config()[:aliases][:"check.static"]

    assert "check.subscriptions_docs_sync" in check_alias
    assert "check.subscriptions_docs_sync" in check_static_alias
  end

  test "task passes when all anchors are present" do
    write_tmp_file(
      @tmp_policy_file,
      """
      ### 5.11 Subscriptions (SubscriptionPlan, Subscription, RenewalAttempt)
      ### 5.12 Entitlements (EntitlementGrant)
      """
    )

    write_tmp_file(
      @tmp_route_file,
      """
      | GET | `/account/subscriptions` |
      | GET | `/account/subscriptions/:id` |
      | GET | `/admin/subscriptions` |
      | GET | `/admin/subscriptions/:id` |
      """
    )

    write_tmp_file(
      @tmp_phase_file,
      """
      ## GOAL
      ## PLAN
      ## PERFORMANCE & SCALING REVIEW
      """
    )

    with_env_overrides(fn ->
      assert :ok == run_task()
    end)
  after
    cleanup_tmp_files()
  end

  test "task fails when policy matrix anchors are missing" do
    write_tmp_file(@tmp_policy_file, "no subscriptions section")
    write_tmp_file(@tmp_route_file, "| GET | `/account/subscriptions` |")
    write_tmp_file(@tmp_phase_file, "## GOAL\n## PLAN\n## PERFORMANCE & SCALING REVIEW")

    with_env_overrides(fn ->
      assert_raise Mix.Error, ~r/Missing anchors/, fn ->
        run_task()
      end
    end)
  after
    cleanup_tmp_files()
  end

  defp run_task do
    Mix.Task.reenable(@task)
    Mix.Task.run(@task)
    :ok
  end

  defp with_env_overrides(fun) do
    with_env("CHECK_SUBSCRIPTIONS_POLICY_MATRIX_FILE", @tmp_policy_file, fn ->
      with_env("CHECK_SUBSCRIPTIONS_ROUTE_INVENTORY_FILE", @tmp_route_file, fn ->
        with_env("CHECK_SUBSCRIPTIONS_PHASE_NOTE_FILE", @tmp_phase_file, fun)
      end)
    end)
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if previous do
        System.put_env(key, previous)
      else
        System.delete_env(key)
      end
    end
  end

  defp write_tmp_file(path, contents) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, contents)
  end

  defp cleanup_tmp_files do
    File.rm(@tmp_policy_file)
    File.rm(@tmp_route_file)
    File.rm(@tmp_phase_file)
  end
end
