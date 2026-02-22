defmodule Store.Payments do
  @moduledoc """
  Payments domain for payment lifecycle and provider event resources.
  """

  use Ash.Domain

  resources do
    resource(Store.Payments.PaymentIntent)
    resource(Store.Payments.ProviderEvent)
  end
end
