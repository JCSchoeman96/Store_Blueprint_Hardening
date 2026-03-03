defmodule Store.Digital.StorageProviders do
  @moduledoc """
  Storage adapter resolver and boundary wrapper.
  """

  alias Store.Digital.StorageProviders.{ExAwsS3Adapter, FakeAdapter}

  @type provider :: :s3 | :fake

  @spec default_provider() :: provider()
  def default_provider do
    Application.get_env(:store, :digital, [])
    |> Keyword.get(:storage_provider, :fake)
    |> normalize_provider!()
  end

  @spec normalize_provider(term()) :: {:ok, provider()} | {:error, :invalid_provider}
  def normalize_provider(provider) do
    case normalize_provider_internal(provider) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_provider}
    end
  end

  @spec adapter(provider()) :: module()
  def adapter(:s3), do: ExAwsS3Adapter
  def adapter(:fake), do: FakeAdapter

  @spec sign_download_url(map() | struct(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sign_download_url(asset, opts \\ []) when is_list(opts) do
    adapter = default_provider() |> adapter()
    adapter.sign_download_url(asset, opts)
  end

  defp normalize_provider!(provider) do
    case normalize_provider_internal(provider) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "invalid digital storage provider"
    end
  end

  defp normalize_provider_internal(provider) when provider in [:s3, "s3", "S3"], do: {:ok, :s3}

  defp normalize_provider_internal(provider) when provider in [:fake, "fake", "FAKE"],
    do: {:ok, :fake}

  defp normalize_provider_internal(_provider), do: :error
end
