defmodule Store.Governance.SubscriptionsErrorCodesTest do
  use ExUnit.Case, async: true

  alias Store.Support.Errors.ErrorCodes

  @phase_subscription_codes [
    "SUBSCRIPTION_NOT_FOUND",
    "SUBSCRIPTION_DUPLICATE",
    "SUBSCRIPTION_RENEWAL_DUPLICATE",
    "SUBSCRIPTION_MISSING_BILLING_REFERENCE",
    "SUBSCRIPTION_PLAN_NOT_FOUND",
    "SUBSCRIPTION_PROVIDER_SELECTION_REQUIRED",
    "SUBSCRIPTION_PROVIDER_UNSUPPORTED",
    "SUBSCRIPTION_PROVIDER_MODE_DISABLED",
    "SUBSCRIPTION_BILLING_MODE_UNSUPPORTED",
    "SUBSCRIPTION_PURCHASE_DISABLED",
    "VARIANT_PLAN_UNAVAILABLE",
    "SHIPPING_PROVIDER_DOWN",
    "SHIPPING_UNAVAILABLE",
    "SHIPPING_PROFILE_MISSING",
    "SHIPPING_COST_SURGE",
    "PAYMENT_METHOD_UPDATE_UNSUPPORTED",
    "PAYMENT_AUTHENTICATION_REQUIRED",
    "PAYMENT_FAILED",
    "PAYMENT_METHOD_REQUIRED",
    "ENTITLEMENT_NOT_FOUND",
    "ENTITLEMENT_DUPLICATE"
  ]

  test "subscription and entitlement error codes exist in registry" do
    for code <- @phase_subscription_codes do
      assert ErrorCodes.exists?(code), "missing subscription error code: #{code}"
    end
  end
end
