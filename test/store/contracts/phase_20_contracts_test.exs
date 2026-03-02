defmodule Store.Contracts.Phase20ContractsTest do
  use ExUnit.Case, async: true

  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Checkout.Inputs.CheckoutStartInput
  alias StoreWeb.Params.Carts.CartItemParams
  alias StoreWeb.Params.Checkout.CheckoutStartParams

  test "cart item input validates variant and qty constraints" do
    assert {:ok, %CartItemInput{qty: 2}} =
             CartItemInput.new(%{"variant_id" => Ash.UUIDv7.generate(), "qty" => "2"})

    assert {:error, error} = CartItemInput.new(%{"variant_id" => "bad", "qty" => 2})
    assert error.code == "VALIDATION_ERROR"

    assert {:error, qty_error} =
             CartItemInput.new(%{"variant_id" => Ash.UUIDv7.generate(), "qty" => 100})

    assert qty_error.code == "VALIDATION_ERROR"
  end

  test "cart load query validates include_items" do
    assert {:ok, %CartLoadQuery{include_items: false}} =
             CartLoadQuery.new(%{"include_items" => "false"})

    assert {:error, error} = CartLoadQuery.new(%{"include_items" => "nope"})
    assert error.code == "VALIDATION_ERROR"
  end

  test "checkout start input rejects unknown params" do
    assert {:ok, %CheckoutStartInput{}} = CheckoutStartInput.new(%{})

    assert {:error, error} = CheckoutStartInput.new(%{"unexpected" => true})
    assert error.code == "VALIDATION_ERROR"
  end

  test "web params adapters delegate to typed contracts" do
    variant_id = Ash.UUIDv7.generate()

    assert {:ok, %CartItemInput{variant_id: ^variant_id, qty: 3}} =
             CartItemParams.input(%{"variant_id" => variant_id, "quantity" => "3"})

    assert {:ok, %CheckoutStartInput{}} = CheckoutStartParams.input(%{})
  end
end
