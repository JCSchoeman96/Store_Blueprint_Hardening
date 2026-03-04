defmodule Store.Governance.SubscriptionsErrorCodesTest do
  use ExUnit.Case, async: true

  alias Store.Support.Errors.ErrorCodes

  @phase_26_codes [
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
    "ENTITLEMENT_NOT_FOUND",
    "ENTITLEMENT_DUPLICATE"
  ]

  test "phase 26 subscription/entitlement error codes exist in registry" do
    for code <- @phase_26_codes do
      assert ErrorCodes.exists?(code), "missing Phase 26 error code: #{code}"
    end
  end
end
