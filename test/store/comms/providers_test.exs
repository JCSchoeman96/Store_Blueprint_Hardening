defmodule Store.Comms.ProvidersTest do
  use ExUnit.Case, async: true

  alias Store.Comms.Providers

  setup do
    original_comms = Application.get_env(:store, :comms, [])

    on_exit(fn ->
      Application.put_env(:store, :comms, original_comms)
    end)

    :ok
  end

  test "normalize_provider accepts only enum values" do
    assert {:ok, :swoosh} = Providers.normalize_provider(:swoosh)
    assert {:ok, :req_postmark} = Providers.normalize_provider(:req_postmark)

    assert {:error, :invalid_provider} = Providers.normalize_provider("swoosh")
    assert {:error, :invalid_provider} = Providers.normalize_provider("REQ_POSTMARK")
    assert {:error, :invalid_provider} = Providers.normalize_provider(:bogus)
  end

  test "default_provider still parses runtime-style string config" do
    Application.put_env(:store, :comms, default_provider: "REQ_POSTMARK")
    assert Providers.default_provider() == :req_postmark
  end
end
