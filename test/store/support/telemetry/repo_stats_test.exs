defmodule Store.Support.Telemetry.RepoStatsTest do
  use Store.DataCase, async: false

  alias Store.Repo
  alias Store.Support.Telemetry.RepoStats

  test "capture counts only queries emitted by the marked process" do
    {result, stats} =
      RepoStats.capture(fn ->
        Repo.query!("SELECT 1", [])
      end)

    assert %Postgrex.Result{} = result
    assert stats.query_count == 1
    assert is_integer(stats.queue_time)
    assert is_integer(stats.query_time)
    assert is_integer(stats.decode_time)
  end

  test "capture does not include unrelated concurrent queries" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Process.sleep(50)
        Repo.query!("SELECT 1", [])
      end)

    assert_receive :ready

    {_result, stats} =
      RepoStats.capture(fn ->
        Process.sleep(100)
        :ok
      end)

    assert stats.query_count == 0
    assert %Postgrex.Result{} = Task.await(task)
  end
end
