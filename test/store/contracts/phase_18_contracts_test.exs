defmodule Store.Contracts.Phase18ContractsTest do
  use ExUnit.Case, async: true

  alias Store.Orders.Queries.{OrderIndexQuery, OrderShowQuery}
  alias Store.Payments.Inputs.WebhookReceiptIngestInput
  alias Store.Payments.Queries.{PaymentIntentIndexQuery, PaymentIntentShowQuery}
  alias StoreWeb.Params.Admin.{ShippingRatesParams, ShippingZonesParams, TaxRatesParams}

  test "order index query rejects unknown keys and coerces limit/offset" do
    assert {:ok, %OrderIndexQuery{limit: 25, offset: 4}} =
             OrderIndexQuery.new(%{"limit" => "25", "offset" => "4"})

    assert {:error, error} = OrderIndexQuery.new(%{"limit" => "1", "unexpected" => "x"})
    assert error.code == "VALIDATION_ERROR"
  end

  test "order show query validates UUID and rejects unknown keys" do
    id = Ecto.UUID.generate()

    assert {:ok, %OrderShowQuery{id: ^id}} = OrderShowQuery.new(%{"id" => id})

    assert {:error, invalid} = OrderShowQuery.new(%{"id" => "not-a-uuid"})
    assert invalid.code == "VALIDATION_ERROR"

    assert {:error, unknown} = OrderShowQuery.new(%{"id" => id, "extra" => "x"})
    assert unknown.code == "VALIDATION_ERROR"
  end

  test "payment intent query contracts reject unknown keys" do
    id = Ecto.UUID.generate()

    assert {:ok, %PaymentIntentIndexQuery{limit: 10, offset: 0}} =
             PaymentIntentIndexQuery.new(%{"limit" => "10"})

    assert {:error, unknown_index} =
             PaymentIntentIndexQuery.new(%{"offset" => "0", "bad" => "x"})

    assert unknown_index.code == "VALIDATION_ERROR"

    assert {:ok, %PaymentIntentShowQuery{id: ^id}} = PaymentIntentShowQuery.new(%{"id" => id})

    assert {:error, unknown_show} = PaymentIntentShowQuery.new(%{"id" => id, "bad" => "x"})
    assert unknown_show.code == "VALIDATION_ERROR"
  end

  test "webhook ingest input rejects unknown keys and validates required fields" do
    params = %{
      "provider" => "stripe",
      "raw_body" => "{\"ok\":true}",
      "headers" => %{"content-type" => ["application/json"]}
    }

    assert {:ok, %WebhookReceiptIngestInput{provider: "stripe"}} =
             WebhookReceiptIngestInput.new(params)

    assert {:error, unknown} = WebhookReceiptIngestInput.new(Map.put(params, "bad", "x"))
    assert unknown.code == "VALIDATION_ERROR"
  end

  test "admin query params adapters reject unknown keys" do
    assert {:ok, _query} = ShippingZonesParams.index_query(%{"limit" => "5"})
    assert {:error, zone_error} = ShippingZonesParams.index_query(%{"limit" => "5", "bad" => "x"})
    assert zone_error.code == "VALIDATION_ERROR"

    assert {:ok, _query} = ShippingRatesParams.index_query(%{"limit" => "5"})
    assert {:error, rate_error} = ShippingRatesParams.index_query(%{"limit" => "5", "bad" => "x"})
    assert rate_error.code == "VALIDATION_ERROR"

    assert {:ok, _query} = TaxRatesParams.index_query(%{"limit" => "5"})
    assert {:error, tax_error} = TaxRatesParams.index_query(%{"limit" => "5", "bad" => "x"})
    assert tax_error.code == "VALIDATION_ERROR"
  end
end
