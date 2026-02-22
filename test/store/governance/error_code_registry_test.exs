defmodule Store.Governance.ErrorCodeRegistryTest do
  use ExUnit.Case, async: true

  alias Store.Support.Errors.ErrorCodes

  @pinned_codes [
    "UNAUTHORIZED",
    "FORBIDDEN",
    "STEP_UP_REQUIRED",
    "INVALID_STATE_TRANSITION",
    "STALE_RECORD",
    "WEBHOOK_DUPLICATE",
    "VALIDATION_ERROR",
    "INVALID_COUPON",
    "CHECKOUT_DUPLICATE",
    "PAYMENT_INTENT_DUPLICATE",
    "PAYMENT_ALREADY_SUCCEEDED",
    "OUT_OF_STOCK",
    "RESERVATION_CONFLICT",
    "REFUND_NOT_ALLOWED",
    "REFUND_EXCEEDS_REFUNDABLE",
    "REFUND_DUPLICATE",
    "PAYMENT_PROVIDER_REFUND_FAILED",
    "INVALID_ADDRESS",
    "SHIPPING_RATE_NOT_FOUND",
    "TAX_RATE_NOT_FOUND",
    "ORDER_NOT_FOUND",
    "ORDER_NOT_OWNED",
    "PAYMENT_PROVIDER_VERIFICATION_FAILED",
    "PAYMENT_EVENT_UNVERIFIED",
    "SLUG_TAKEN",
    "SKU_TAKEN"
  ]

  test "registry is unique and SCREAMING_SNAKE_CASE" do
    codes = ErrorCodes.all()

    assert Enum.uniq(codes) == codes
    assert Enum.all?(codes, &Regex.match?(~r/^[A-Z0-9_]+$/, &1))
  end

  test "registry contains all pinned governance codes" do
    for code <- @pinned_codes do
      assert ErrorCodes.exists?(code), "missing pinned code: #{code}"
    end
  end
end
