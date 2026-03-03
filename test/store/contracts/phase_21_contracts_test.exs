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
    assert {:ok, %CreateIntentForOrderInput{provider: :stripe}} =
             CreateIntentForOrderInput.new(%{})

    assert {:ok, %CreateIntentForOrderInput{provider: :stripe}} =
             CreateIntentForOrderInput.new(%{"provider" => "stripe"})

    assert {:error, error} = CreateIntentForOrderInput.new(%{"bad" => "x"})
    assert error.code == "VALIDATION_ERROR"
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
