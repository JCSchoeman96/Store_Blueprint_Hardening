defmodule Store.ReleaseTest do
  use Store.DataCase, async: false

  import ExUnit.CaptureIO

  test "preflight emits a successful report" do
    output =
      capture_io(fn ->
        report = Store.Release.preflight()
        assert report.command == "preflight"
        assert report.status == "ok"
        assert report.readiness.status == "ok"
        assert report.runtime.status == "ok"
      end)

    assert output =~ "\"command\": \"preflight\""
  end

  test "migrate emits a successful report" do
    output =
      capture_io(fn ->
        report = Store.Release.migrate()
        assert report.command == "migrate"
        assert report.status == "ok"
        assert [%{status: "ok", repo: "Store.Repo"}] = report.migrated
      end)

    assert output =~ "\"command\": \"migrate\""
  end

  test "migrate_all emits a successful report without duplicate migration targets" do
    output =
      capture_io(fn ->
        report = Store.Release.migrate_all()
        assert report.command == "migrate_all"
        assert report.status == "ok"
        assert Enum.count(report.migrated) == 1
        assert [%{status: "ok", repo: "Store.Repo"}] = report.migrated
      end)

    assert output =~ "\"command\": \"migrate_all\""
  end

  test "restore audit emits a successful report" do
    output =
      capture_io(fn ->
        report = Store.Release.restore_audit()
        assert report.command == "restore_audit"
        assert report.status == "ok"
        assert report.readiness.status == "ok"
        assert report.restore_audit.status == "ok"
      end)

    assert output =~ "\"command\": \"restore_audit\""
  end
end
