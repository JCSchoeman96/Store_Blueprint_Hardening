defmodule Store.Digital.StorageProvider do
  @moduledoc """
  Behaviour for signing short-lived download URLs.
  """

  @type asset :: map() | struct()

  @callback sign_download_url(asset(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
