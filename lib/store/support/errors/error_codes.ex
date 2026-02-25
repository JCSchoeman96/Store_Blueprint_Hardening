defmodule Store.Support.Errors.ErrorCodes do
  @moduledoc """
  Stable, registry-backed error codes.
  """

  @codes [
    "UNAUTHORIZED",
    "FORBIDDEN",
    "NOT_FOUND",
    "STEP_UP_REQUIRED",
    "INVALID_STATE_TRANSITION",
    "STALE_RECORD",
    "WEBHOOK_DUPLICATE",
    "VALIDATION_ERROR",
    "INTERNAL_ERROR",
    "INVALID_COUPON",
    "CHECKOUT_DUPLICATE",
    "PAYMENT_INTENT_DUPLICATE",
    "PAYMENT_ALREADY_SUCCEEDED",
    "OUT_OF_STOCK",
    "RESERVATION_CONFLICT",
    "REFUND_NOT_ALLOWED",
    "REFUND_EXCEEDS_REFUNDABLE",
    "REFUND_DUPLICATE",
    "IDEMPOTENCY_KEY_REUSE_MISMATCH",
    "CURRENCY_MISMATCH",
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

  @compile {:inline, exists?: 1}
  @codes_map Map.new(@codes, &{&1, true})

  if length(@codes) != map_size(@codes_map) do
    raise "duplicate error codes in Store.Support.Errors.ErrorCodes"
  end

  @spec all() :: [String.t()]
  def all do
    Enum.sort(@codes)
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(code) when is_binary(code) do
    Map.has_key?(@codes_map, code)
  end
end
