defmodule Store.Digital.StorageProviders.FakeAdapter do
  @moduledoc """
  Deterministic fake storage signing adapter for dev/test.
  """

  @behaviour Store.Digital.StorageProvider

  @impl true
  def sign_download_url(asset, opts \\ []) do
    ttl_seconds = ttl_seconds(opts)
    host = Application.get_env(:store, :digital, []) |> Keyword.get(:fake_host, "downloads.local")

    with {:ok, object_key} <- fetch_field(asset, :storage_object_key),
         {:ok, asset_id} <- fetch_field(asset, :id) do
      query =
        URI.encode_query(%{
          "asset_id" => asset_id,
          "object_key" => object_key,
          "exp" => Integer.to_string(System.system_time(:second) + ttl_seconds)
        })

      {:ok, "https://#{host}/digital/fake-download?#{query}"}
    end
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
