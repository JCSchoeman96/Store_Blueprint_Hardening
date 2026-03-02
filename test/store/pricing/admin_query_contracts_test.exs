defmodule Store.Pricing.AdminQueryContractsTest do
  use ExUnit.Case, async: true

  alias Store.Pricing.Queries.{
    AdminShippingRatesQuery,
    AdminShippingZonesQuery,
    AdminTaxRatesQuery
  }

  describe "AdminShippingZonesQuery.new/1" do
    test "rejects unknown keys" do
      assert {:error, error} = AdminShippingZonesQuery.new(%{"oops" => "nope"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "rejects non-integer limit" do
      assert {:error, error} = AdminShippingZonesQuery.new(%{"limit" => "abc"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "clamps limit into range" do
      assert {:ok, query} = AdminShippingZonesQuery.new(%{"limit" => 9999})
      assert query.limit == 100

      assert {:ok, query} = AdminShippingZonesQuery.new(%{"limit" => 0})
      assert query.limit == 1
    end
  end

  describe "AdminShippingRatesQuery.new/1" do
    test "rejects unknown keys" do
      assert {:error, error} = AdminShippingRatesQuery.new(%{"oops" => "nope"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "rejects non-integer limit" do
      assert {:error, error} = AdminShippingRatesQuery.new(%{"limit" => "abc"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "validates shipping_zone_id format" do
      assert {:error, error} = AdminShippingRatesQuery.new(%{"shipping_zone_id" => "bad"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "clamps limit into range" do
      assert {:ok, query} = AdminShippingRatesQuery.new(%{"limit" => 200})
      assert query.limit == 100

      assert {:ok, query} = AdminShippingRatesQuery.new(%{"limit" => -1})
      assert query.limit == 1
    end
  end

  describe "AdminTaxRatesQuery.new/1" do
    test "rejects unknown keys" do
      assert {:error, error} = AdminTaxRatesQuery.new(%{"oops" => "nope"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "rejects non-integer limit" do
      assert {:error, error} = AdminTaxRatesQuery.new(%{"limit" => "abc"})
      assert error.code == "VALIDATION_ERROR"
    end

    test "clamps limit into range" do
      assert {:ok, query} = AdminTaxRatesQuery.new(%{"limit" => 2_000})
      assert query.limit == 100
    end
  end
end
