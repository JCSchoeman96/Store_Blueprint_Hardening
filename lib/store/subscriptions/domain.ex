defmodule Store.Subscriptions do
  @moduledoc """
  Subscriptions domain for plan catalog, lifecycle, and renewal attempts.
  """

  use Ash.Domain

  resources do
    resource(Store.Subscriptions.SubscriptionPlan)
    resource(Store.Subscriptions.VariantSubscriptionPlan)
    resource(Store.Subscriptions.StoredPaymentMethod)
    resource(Store.Subscriptions.Subscription)
    resource(Store.Subscriptions.SubscriptionItem)
    resource(Store.Subscriptions.RenewalAttempt)
  end
end
