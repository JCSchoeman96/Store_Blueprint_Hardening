defmodule Store.Digital.StorageProviders.ExAwsS3Adapter do
  @moduledoc """
  S3-compatible presigned URL adapter.
  """

  @behaviour Store.Digital.StorageProvider

  @impl true
  def sign_download_url(asset, opts \\ []) do
    with {:ok, bucket} <- fetch_field(asset, :storage_bucket),
         {:ok, object_key} <- fetch_field(asset, :storage_object_key),
         ttl_seconds <- ttl_seconds(opts),
         ex_aws_config <- ex_aws_config() do
      ExAws.S3.presigned_url(ex_aws_config, :get, bucket, object_key, expires_in: ttl_seconds)
    end
  end

  defp ex_aws_config do
    Application.get_env(:store, :digital, [])
    |> Keyword.get(:s3, [])
    |> ExAws.Config.new(:s3)
  end

  defp ttl_seconds(opts) do
    opts
    |> Keyword.get(:ttl_seconds, default_ttl_seconds())
    |> clamp_ttl()
  end

  defp default_ttl_seconds do
    Application.get_env(:store, :digital, [])
    |> Keyword.get(:signed_url_ttl_seconds, 120)
  end

  defp clamp_ttl(value) when is_integer(value) and value < 60, do: 60
  defp clamp_ttl(value) when is_integer(value) and value > 300, do: 300
  defp clamp_ttl(value) when is_integer(value), do: value
  defp clamp_ttl(_value), do: 120

  defp fetch_field(asset, field) do
    value =
      if is_map(asset) do
        Map.get(asset, field) || Map.get(asset, Atom.to_string(field))
      else
        nil
      end

    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, {:missing_field, field}}
  end
end
