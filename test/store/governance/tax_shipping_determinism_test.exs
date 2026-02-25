defmodule Store.Governance.TaxShippingDeterminismTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Pricing

  alias Store.Pricing.{
    ShippingRate,
    ShippingZone,
    TaxRate,
    TaxShippingContract,
    TaxShippingEvaluator
  }

  alias Store.Support.Errors.Error

  test "tax/shipping evaluation is deterministic for identical inputs" do
    input = deterministic_input()

    outputs =
      1..15
      |> Enum.map(fn _ ->
        assert {:ok, output} = TaxShippingEvaluator.evaluate(input)
        output
      end)

    [first | rest] = outputs
    assert Enum.all?(rest, &(&1 == first))
  end

  test "shipping tie-break uses cost then UUID binary sort then code" do
    input =
      TaxShippingContract.to_input!(%{
        as_of: ~U[2026-02-25 12:00:00Z],
        currency: "USD",
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94107",
        subtotal_minor: 2_000,
        shipping_weight_grams: 500,
        lines: [
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd9",
            line_no: 1,
            net_line_total_minor: 2_000,
            tax_category_snapshot: "STANDARD"
          }
        ],
        shipping_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd8",
            code: "RATE_B",
            shipping_cost_minor: 500,
            country_code: "US",
            region_code: "CA",
            active?: true
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd7",
            code: "RATE_A",
            shipping_cost_minor: 500,
            country_code: "US",
            region_code: "CA",
            active?: true
          }
        ],
        tax_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd6",
            code: "US_CA_STD",
            country_code: "US",
            region_code: "CA",
            rate_basis_points: 850,
            shipping_taxable: true,
            active?: true
          }
        ],
        free_shipping_coupon?: false,
        shipping_enabled?: true,
        tax_enabled?: true
      })

    assert {:ok, output} = TaxShippingEvaluator.evaluate(input)
    assert output.selected_shipping_rate_id == "018ecb40-c457-73e6-a400-000398daddd7"
  end

  test "tax and shipping totals have no penny leak" do
    input =
      TaxShippingContract.to_input!(%{
        as_of: ~U[2026-02-25 12:00:00Z],
        currency: "USD",
        destination_country_code: "US",
        destination_region_code: "CA",
        subtotal_minor: 303,
        shipping_weight_grams: 1_000,
        lines: [
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd7",
            line_no: 1,
            net_line_total_minor: 101,
            tax_category_snapshot: "STANDARD"
          },
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd8",
            line_no: 2,
            net_line_total_minor: 101,
            tax_category_snapshot: "STANDARD"
          },
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd9",
            line_no: 3,
            net_line_total_minor: 101,
            tax_category_snapshot: "STANDARD"
          }
        ],
        shipping_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddda",
            code: "GROUND",
            shipping_cost_minor: 101,
            country_code: "US",
            region_code: "CA",
            active?: true
          }
        ],
        tax_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398dadddb",
            code: "US_CA_STD",
            country_code: "US",
            region_code: "CA",
            rate_basis_points: 875,
            shipping_taxable: true,
            active?: true
          }
        ],
        free_shipping_coupon?: false,
        shipping_enabled?: true,
        tax_enabled?: true
      })

    assert {:ok, output} = TaxShippingEvaluator.evaluate(input)

    assert output.shipping_cost_minor_effective == 101
    assert output.shipping_tax_minor == 9
    assert output.tax_total_minor == 36
    assert output.order_total_minor == 440

    line_tax_sum = Enum.reduce(output.line_taxes, 0, &(&1.tax_minor + &2))
    assert line_tax_sum + output.shipping_tax_minor == output.tax_total_minor

    assert output.subtotal_minor + output.shipping_cost_minor_effective + output.tax_total_minor ==
             output.order_total_minor
  end

  test "snapshot evidence is write-once and remains stable after rate changes" do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{order_ref: "ORDTAXSHIPIMM001"})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    line_item =
      OrderLineItem
      |> Ash.Changeset.for_create(:create, %{
        order_id: order.id,
        line_no: 1,
        currency: "USD",
        quantity: 1,
        unit_price_minor: 10_000,
        line_total_minor: 10_000,
        sku_snapshot: "SKU-TAX-1",
        product_title_snapshot: "Tax Product",
        variant_title_snapshot: "Default",
        discount_allocated_minor: 0,
        net_line_total_minor: 10_000
      })
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(:create, %{
        code: "US-CA",
        country_code: "US",
        region_code: "CA",
        active: true
      })
      |> Ash.create!(domain: Pricing, authorize?: false)

    shipping_rate =
      ShippingRate
      |> Ash.Changeset.for_create(:create, %{
        code: "GROUND_US_CA",
        currency: "USD",
        shipping_zone_id: zone.id,
        shipping_cost_minor: 899,
        active: true
      })
      |> Ash.create!(domain: Pricing, authorize?: false)

    tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(:create, %{
        code: "US_CA_STANDARD",
        country_code: "US",
        region_code: "CA",
        product_tax_category: "STANDARD",
        rate_basis_points: 925,
        shipping_taxable: true,
        active: true
      })
      |> Ash.create!(domain: Pricing, authorize?: false)

    attrs = %{
      as_of: ~U[2026-02-25 12:00:00Z],
      currency: "USD",
      destination_country_code: "US",
      destination_region_code: "CA",
      destination_postal_code: "94107",
      subtotal_minor: 10_000,
      shipping_weight_grams: 1_200,
      lines: [
        %{
          line_id: line_item.id,
          line_no: line_item.line_no,
          net_line_total_minor: line_item.net_line_total_minor,
          tax_category_snapshot: "STANDARD"
        }
      ],
      free_shipping_coupon?: false
    }

    assert {:ok, %{output: first_output}} = Pricing.evaluate_tax_shipping_quote(attrs)

    assert {:ok, first_write} =
             Store.Orders.write_tax_shipping_snapshot(order.id, first_output)

    refute first_write.idempotent?

    _shipping_rate_updated =
      shipping_rate
      |> Ash.Changeset.for_update(:update, %{shipping_cost_minor: 1_499},
        context: %{system?: true}
      )
      |> Ash.update!(domain: Pricing, authorize?: false, context: %{system?: true})

    _tax_rate_updated =
      tax_rate
      |> Ash.Changeset.for_update(:update, %{rate_basis_points: 1_150}, context: %{system?: true})
      |> Ash.update!(domain: Pricing, authorize?: false, context: %{system?: true})

    assert {:ok, %{output: second_output}} = Pricing.evaluate_tax_shipping_quote(attrs)
    assert second_output.order_total_minor != first_output.order_total_minor

    assert {:ok, second_write} =
             Store.Orders.write_tax_shipping_snapshot(order.id, second_output)

    assert second_write.idempotent?

    persisted_order =
      Order
      |> Ash.Query.filter(expr(id == ^order.id))
      |> Ash.read_one!(domain: Store.Orders, authorize?: false)

    assert persisted_order.shipping_cost_minor_original ==
             first_output.shipping_cost_minor_original

    assert persisted_order.shipping_cost_minor_effective ==
             first_output.shipping_cost_minor_effective

    assert persisted_order.tax_total_minor == first_output.tax_total_minor
  end

  test "error codes are deterministic for invalid address and missing rates" do
    invalid_address_input =
      TaxShippingContract.to_input!(%{
        as_of: ~U[2026-02-25 12:00:00Z],
        currency: "USD",
        destination_country_code: "",
        subtotal_minor: 500,
        shipping_weight_grams: 100,
        lines: [
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd7",
            line_no: 1,
            net_line_total_minor: 500,
            tax_category_snapshot: "STANDARD"
          }
        ],
        shipping_rates: [],
        tax_rates: []
      })

    assert {:error, %Error{code: "INVALID_ADDRESS"}} =
             TaxShippingEvaluator.evaluate(invalid_address_input)

    no_shipping_rate_input =
      TaxShippingContract.to_input!(%{
        as_of: ~U[2026-02-25 12:00:00Z],
        currency: "USD",
        destination_country_code: "US",
        destination_region_code: "CA",
        subtotal_minor: 500,
        shipping_weight_grams: 100,
        lines: [
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd7",
            line_no: 1,
            net_line_total_minor: 500,
            tax_category_snapshot: "STANDARD"
          }
        ],
        shipping_rates: [],
        tax_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd9",
            code: "US_CA_STANDARD",
            country_code: "US",
            region_code: "CA",
            rate_basis_points: 800,
            shipping_taxable: true
          }
        ]
      })

    assert {:error, %Error{code: "SHIPPING_RATE_NOT_FOUND"}} =
             TaxShippingEvaluator.evaluate(no_shipping_rate_input)

    no_tax_rate_input =
      TaxShippingContract.to_input!(%{
        as_of: ~U[2026-02-25 12:00:00Z],
        currency: "USD",
        destination_country_code: "US",
        destination_region_code: "CA",
        subtotal_minor: 500,
        shipping_weight_grams: 100,
        lines: [
          %{
            line_id: "018ecb40-c457-73e6-a400-000398daddd7",
            line_no: 1,
            net_line_total_minor: 500,
            tax_category_snapshot: "STANDARD"
          }
        ],
        shipping_rates: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd8",
            code: "GROUND",
            shipping_cost_minor: 50,
            country_code: "US",
            region_code: "CA"
          }
        ],
        tax_rates: []
      })

    assert {:error, %Error{code: "TAX_RATE_NOT_FOUND"}} =
             TaxShippingEvaluator.evaluate(no_tax_rate_input)
  end

  defp deterministic_input do
    TaxShippingContract.to_input!(%{
      as_of: ~U[2026-02-25 12:00:00Z],
      currency: "USD",
      destination_country_code: "US",
      destination_region_code: "CA",
      destination_postal_code: "94107",
      subtotal_minor: 8_500,
      shipping_weight_grams: 1_100,
      lines: [
        %{
          line_id: "018ecb40-c457-73e6-a400-000398daddd7",
          line_no: 1,
          net_line_total_minor: 5_000,
          tax_category_snapshot: "STANDARD"
        },
        %{
          line_id: "018ecb40-c457-73e6-a400-000398daddd8",
          line_no: 2,
          net_line_total_minor: 3_500,
          tax_category_snapshot: "STANDARD"
        }
      ],
      shipping_rates: [
        %{
          id: "018ecb40-c457-73e6-a400-000398daddda",
          code: "US_CA_GROUND",
          shipping_cost_minor: 799,
          country_code: "US",
          region_code: "CA",
          weight_min_grams: 0,
          weight_max_grams: 2_000,
          free_over_subtotal_minor: 10_000,
          allow_free_shipping_coupon: false
        },
        %{
          id: "018ecb40-c457-73e6-a400-000398dadddb",
          code: "US_CA_PRIORITY",
          shipping_cost_minor: 1_299,
          country_code: "US",
          region_code: "CA",
          weight_min_grams: 0,
          weight_max_grams: 2_000,
          free_over_subtotal_minor: 20_000,
          allow_free_shipping_coupon: false
        }
      ],
      tax_rates: [
        %{
          id: "018ecb40-c457-73e6-a400-000398dadddc",
          code: "US_CA_STANDARD",
          country_code: "US",
          region_code: "CA",
          product_tax_category: "STANDARD",
          rate_basis_points: 925,
          shipping_taxable: true,
          precedence_rank: 100
        }
      ],
      free_shipping_coupon?: false,
      shipping_enabled?: true,
      tax_enabled?: true
    })
  end
end
