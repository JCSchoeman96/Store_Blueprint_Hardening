defmodule Store.Contracts.Phase21ContractsTest do
  use ExUnit.Case, async: true

  alias Store.Checkout.Inputs.{CheckoutFinalizeInput, CheckoutShippingInput}
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias StoreWeb.Params.Checkout.{CheckoutFinalizeParams, CheckoutShippingParams}
  alias StoreWeb.Params.Payments.CreateIntentForOrderParams

  test "checkout shipping input validates required and unknown keys" do
    assert {:error, error} = CheckoutShippingInput.new(%{"oops" => "x"})
    assert error.code == "VALIDATION_ERROR"

    assert {:ok, _input} =
             CheckoutShippingInput.new(%{
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "quote_hash" => "abc123",
               "shipping_method_code" => "GROUND"
             })
  end

  test "checkout finalize input only accepts empty map" do
    assert {:ok, %CheckoutFinalizeInput{}} = CheckoutFinalizeInput.new(%{})
    assert {:error, error} = CheckoutFinalizeInput.new(%{"unexpected" => true})
    assert error.code == "VALIDATION_ERROR"
  end

  test "create intent input accepts provider only" do
    assert {:error, missing_provider_error} = CreateIntentForOrderInput.new(%{})
    assert missing_provider_error.code == "PAYMENT_PROVIDER_SELECTION_REQUIRED"

    assert {:ok, %CreateIntentForOrderInput{provider: :stripe}} =
             CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, unsupported_provider_error} =
             CreateIntentForOrderInput.new(%{"provider" => "bogus"})

    assert unsupported_provider_error.code == "PAYMENT_PROVIDER_UNSUPPORTED"

    assert {:error, unknown_key_error} = CreateIntentForOrderInput.new(%{"bad" => "x"})
    assert unknown_key_error.code == "VALIDATION_ERROR"
  end

  test "web params adapters return typed inputs" do
    assert {:ok, %CheckoutFinalizeInput{}} = CheckoutFinalizeParams.input(%{})

    assert {:ok, %CreateIntentForOrderInput{provider: :stripe}} =
             CreateIntentForOrderParams.input(%{"provider" => "stripe"})

    assert {:ok, _shipping_input} =
             CheckoutShippingParams.input(%{
               "address_line1" => "1 Main St",
               "city" => "San Francisco",
               "country_code" => "US",
               "region_code" => "CA",
               "postal_code" => "94105",
               "quote_hash" => "abc123",
               "shipping_method_code" => "GROUND"
             })
  end
end
