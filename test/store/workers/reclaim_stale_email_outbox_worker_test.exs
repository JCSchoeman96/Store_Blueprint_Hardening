defmodule Store.Workers.ReclaimStaleEmailOutboxWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.Repo

  alias Store.Workers.ReclaimStaleEmailOutboxWorker

  test "worker executes reclaim flow successfully" do
    assert :ok = perform_job(ReclaimStaleEmailOutboxWorker, %{})
  end
end
