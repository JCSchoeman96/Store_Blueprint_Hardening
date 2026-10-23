defmodule Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorker

  test "perform runs reconciliation and accepts bounded limit" do
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert :ok =
             perform_job(
               ReconcileSubscriptionAccessEffectTargetOrderWorker,
               %{
                 "as_of" => DateTime.to_iso8601(as_of),
                 "limit" => 25,
                 "skip_effective" => true,
                 "skip_non_effective" => true
               }
             )
  end

  test "invalid cursor discards the job" do
    assert {:discard, _} =
             perform_job(
               ReconcileSubscriptionAccessEffectTargetOrderWorker,
               %{"limit" => "not-a-number"}
             )
  end
end
