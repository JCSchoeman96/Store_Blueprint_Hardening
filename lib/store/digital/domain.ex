defmodule Store.Digital do
  @moduledoc """
  Digital fulfillment domain for assets, product links, and customer grants.
  """

  use Ash.Domain

  resources do
    resource(Store.Digital.DigitalAsset)
    resource(Store.Digital.ProductDigitalLink)
    resource(Store.Digital.DownloadGrant)
  end
end
