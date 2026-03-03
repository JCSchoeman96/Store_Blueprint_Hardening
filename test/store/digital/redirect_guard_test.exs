defmodule Store.Digital.RedirectGuardTest do
  use ExUnit.Case, async: true

  alias Store.Digital.RedirectGuard

  setup do
    previous = Application.get_env(:store, :digital, [])

    Application.put_env(
      :store,
      :digital,
      Keyword.merge(previous,
        allowed_redirect_hosts: ["downloads.local", "bucket.wasabisys.com"]
      )
    )

    on_exit(fn -> Application.put_env(:store, :digital, previous) end)
    :ok
  end

  test "accepts https URL on allowlisted host" do
    assert :ok ==
             RedirectGuard.validate_signed_url(
               "https://downloads.local/digital/fake-download?asset_id=123"
             )
  end

  test "rejects non-https URL" do
    assert {:error, error} =
             RedirectGuard.validate_signed_url(
               "http://downloads.local/digital/fake-download?asset_id=123"
             )

    assert error.code == "DIGITAL_REDIRECT_UNSAFE"
  end

  test "rejects host outside allowlist" do
    assert {:error, error} =
             RedirectGuard.validate_signed_url(
               "https://evil.example.com/digital/fake-download?asset_id=123"
             )

    assert error.code == "DIGITAL_REDIRECT_UNSAFE"
  end
end
