defmodule Store.Digital.StorageProvidersTest do
  use ExUnit.Case, async: true

  alias Store.Digital.StorageProviders

  setup do
    previous = Application.get_env(:store, :digital, [])

    Application.put_env(
      :store,
      :digital,
      Keyword.merge(previous,
        storage_provider: :fake,
        fake_host: "downloads.local",
        signed_url_ttl_seconds: 120
      )
    )

    on_exit(fn -> Application.put_env(:store, :digital, previous) end)
    :ok
  end

  test "normalizes provider values" do
    assert {:ok, :s3} = StorageProviders.normalize_provider("s3")
    assert {:ok, :fake} = StorageProviders.normalize_provider("FAKE")
    assert {:error, :invalid_provider} = StorageProviders.normalize_provider("gcs")
  end

  test "fake provider signs deterministic HTTPS URL" do
    assert {:ok, url} =
             StorageProviders.sign_download_url(%{
               id: "018f2f95-95f5-7f6e-b23a-5a6f2f0f2d50",
               storage_object_key: "digital/ebook.pdf"
             })

    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")

    assert uri.scheme == "https"
    assert uri.host == "downloads.local"
    assert query["asset_id"] == "018f2f95-95f5-7f6e-b23a-5a6f2f0f2d50"
    assert query["object_key"] == "digital/ebook.pdf"
    assert is_binary(query["exp"])
  end
end
