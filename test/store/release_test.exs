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
