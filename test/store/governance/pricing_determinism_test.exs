defmodule Store.Governance.PricingDeterminismTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{Order, OrderAdjustment, OrderLineItem}
  alias Store.Pricing
  alias Store.Pricing.{Contract, Coupon, Evaluator, Promotion}

  test "pricing evaluation is deterministic for identical inputs" do
    input = deterministic_input()

    outputs =
      1..15
      |> Enum.map(fn _ ->
        assert {:ok, output} = Evaluator.evaluate(input)
        output
      end)

    [first | rest] = outputs
    assert Enum.all?(rest, &(&1 == first))
  end

  test "exclusive tie-break selection is stable and uses id bytes as final key" do
    as_of = ~U[2026-02-24 12:00:00Z]
    inserted_at = ~U[2026-02-24 11:00:00Z]

    input =
      Contract.to_input!(%{
        as_of: as_of,
        currency: "USD",
        lines: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd9",
            line_no: 1,
            sku_snapshot: "sku-1",
            product_title_snapshot: "Widget",
            quantity: 1,
            unit_price_minor: 1000,
            line_total_minor: 1000
          }
        ],
        promotions: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd8",
            source_kind: :promotion,
            code: "PROMO_B",
            discount_minor: 500,
            active?: true,
            exclusive?: true,
            combinable?: false,
            exclusive_priority: 10,
            precedence_rank: 200,
            inserted_at: inserted_at
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd7",
            source_kind: :promotion,
            code: "PROMO_A",
            discount_minor: 500,
            active?: true,
            exclusive?: true,
            combinable?: false,
            exclusive_priority: 10,
            precedence_rank: 200,
            inserted_at: inserted_at
          }
        ],
        eligibility: %{}
      })

    assert {:ok, output} = Evaluator.evaluate(input)

    assert [%Contract.AppliedAdjustment{source_id: winner_id}] = output.applied_adjustments
    assert winner_id == "018ecb40-c457-73e6-a400-000398daddd7"
  end

  test "discount allocation has no penny leak with deterministic remainder distribution" do
    as_of = ~U[2026-02-24 12:00:00Z]

    input =
      Contract.to_input!(%{
        as_of: as_of,
        currency: "USD",
        lines: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd9",
            line_no: 3,
            sku_snapshot: "sku-3",
            product_title_snapshot: "Widget 3",
            quantity: 1,
            unit_price_minor: 101,
            line_total_minor: 101
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd7",
            line_no: 1,
            sku_snapshot: "sku-1",
            product_title_snapshot: "Widget 1",
            quantity: 1,
            unit_price_minor: 101,
            line_total_minor: 101
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd8",
            line_no: 2,
            sku_snapshot: "sku-2",
            product_title_snapshot: "Widget 2",
            quantity: 1,
            unit_price_minor: 101,
            line_total_minor: 101
          }
        ],
        promotions: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddda",
            source_kind: :promotion,
            code: "PROMO_REMAINDER",
            discount_minor: 100,
            active?: true,
            exclusive?: false,
            combinable?: true,
            precedence_rank: 200,
            inserted_at: ~U[2026-02-24 11:00:00Z]
          }
        ],
        eligibility: %{}
      })

    assert {:ok, output} = Evaluator.evaluate(input)

    allocated_sum = Enum.reduce(output.line_allocations, 0, &(&1.discount_minor + &2))
    assert allocated_sum == output.discount_total_minor
    assert output.discount_total_minor == 100

    expected = [
      {"018ecb40-c457-73e6-a400-000398daddd7", 34},
      {"018ecb40-c457-73e6-a400-000398daddd8", 33},
      {"018ecb40-c457-73e6-a400-000398daddd9", 33}
    ]

    actual = Enum.map(output.line_allocations, &{&1.line_id, &1.discount_minor})
    assert actual == expected
  end

  test "applied discount ordering is deterministic" do
    as_of = ~U[2026-02-24 12:00:00Z]

    input =
      Contract.to_input!(%{
        as_of: as_of,
        currency: "USD",
        lines: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddd9",
            line_no: 1,
            sku_snapshot: "sku-1",
            product_title_snapshot: "Widget",
            quantity: 1,
            unit_price_minor: 5000,
            line_total_minor: 5000
          }
        ],
        coupon: %{
          id: "018ecb40-c457-73e6-a400-000398daddf0",
          source_kind: :coupon,
          code: "WELCOME10",
          discount_minor: 40,
          active?: true,
          combinable?: true,
          allow_with_exclusive?: false,
          precedence_rank: 50,
          inserted_at: ~U[2026-02-24 11:59:00Z]
        },
        promotions: [
          %{
            id: "018ecb40-c457-73e6-a400-000398daddf3",
            source_kind: :promotion,
            code: "PROMO_B",
            discount_minor: 60,
            active?: true,
            exclusive?: false,
            combinable?: true,
            precedence_rank: 200,
            inserted_at: ~U[2026-02-24 11:58:00Z]
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddf1",
            source_kind: :promotion,
            code: "PROMO_A",
            discount_minor: 60,
            active?: true,
            exclusive?: false,
            combinable?: true,
            precedence_rank: 200,
            inserted_at: ~U[2026-02-24 11:58:00Z]
          },
          %{
            id: "018ecb40-c457-73e6-a400-000398daddf2",
            source_kind: :promotion,
            code: "PROMO_C",
            discount_minor: 60,
            active?: true,
            exclusive?: false,
            combinable?: true,
            precedence_rank: 150,
            inserted_at: ~U[2026-02-24 11:58:30Z]
          }
        ],
        eligibility: %{}
      })

    assert {:ok, output} = Evaluator.evaluate(input)

    assert Enum.map(
             output.applied_adjustments,
             &{&1.source_kind, &1.precedence_rank, &1.source_id}
           ) == [
             {:coupon, 50, "018ecb40-c457-73e6-a400-000398daddf0"},
             {:promotion, 150, "018ecb40-c457-73e6-a400-000398daddf2"},
             {:promotion, 200, "018ecb40-c457-73e6-a400-000398daddf1"},
             {:promotion, 200, "018ecb40-c457-73e6-a400-000398daddf3"}
           ]
  end

  test "snapshot evidence remains immutable after later promotion changes" do
    as_of = ~U[2026-02-24 12:00:00Z]

    order =
      Order
      |> Ash.Changeset.for_create(:create, %{order_ref: "ORDPRICEIMM001"})
      |> Ash.create!(domain: Store.Orders, authorize?: false)

    promotion =
      Promotion
      |> Ash.Changeset.for_create(:create, %{
        code: "PROMO_IMMUTABLE",
        currency: "USD",
        discount_minor: 175,
        active: true,
        exclusive: false,
        combinable: true,
        exclusive_priority: 0,
        precedence_rank: 200
      })
      |> Ash.create!(domain: Pricing, authorize?: false)

    assert {:ok, %{output: first_output}} =
             Pricing.evaluate_quote(%{
               as_of: as_of,
               currency: "USD",
               lines: snapshot_lines(),
               promotion_ids: [promotion.id],
               eligibility: %{}
             })

    assert {:ok, first_write} = Store.Orders.write_priced_snapshot(order.id, first_output)
    refute first_write.idempotent?

    assert {:ok, _updated_promotion} =
             promotion
             |> Ash.Changeset.for_update(:update, %{discount_minor: 325})
             |> Ash.update(domain: Pricing, authorize?: false)

    assert {:ok, %{output: second_output}} =
             Pricing.evaluate_quote(%{
               as_of: as_of,
               currency: "USD",
               lines: snapshot_lines(),
               promotion_ids: [promotion.id],
               eligibility: %{}
             })

    assert second_output.discount_total_minor != first_output.discount_total_minor

    assert {:ok, second_write} = Store.Orders.write_priced_snapshot(order.id, second_output)
    assert second_write.idempotent?

    line_items = read_line_items(order.id)
    adjustments = read_adjustments(order.id)

    assert Enum.map(line_items, & &1.net_line_total_minor) ==
             Enum.map(first_output.lines, & &1.net_line_total_minor)

    stored_discount =
      adjustments
      |> Enum.map(&abs(&1.amount_minor))
      |> Enum.sum()

    assert stored_discount == first_output.discount_total_minor
    assert stored_discount != second_output.discount_total_minor
  end

  defp deterministic_input do
    Contract.to_input!(%{
      as_of: ~U[2026-02-24 12:00:00Z],
      currency: "USD",
      lines: snapshot_lines(),
      coupon: %{
        id: "018ecb40-c457-73e6-a400-000398daddd6",
        source_kind: :coupon,
        code: "WELCOME25",
        discount_minor: 250,
        active?: true,
        combinable?: true,
        precedence_rank: 50,
        inserted_at: ~U[2026-02-24 11:40:00Z]
      },
      promotions: [
        %{
          id: "018ecb40-c457-73e6-a400-000398daddd8",
          source_kind: :promotion,
          code: "PROMO_A",
          discount_minor: 300,
          active?: true,
          exclusive?: false,
          combinable?: true,
          precedence_rank: 200,
          inserted_at: ~U[2026-02-24 11:30:00Z]
        },
        %{
          id: "018ecb40-c457-73e6-a400-000398daddd7",
          source_kind: :promotion,
          code: "PROMO_B",
          discount_minor: 150,
          active?: true,
          exclusive?: false,
          combinable?: true,
          precedence_rank: 210,
          inserted_at: ~U[2026-02-24 11:20:00Z]
        }
      ],
      eligibility: %{}
    })
  end

  defp snapshot_lines do
    [
      %{
        id: "018ecb40-c457-73e6-a400-000398daddd9",
        line_no: 3,
        sku_snapshot: "sku-3",
        product_title_snapshot: "Widget 3",
        variant_title_snapshot: "Blue",
        quantity: 1,
        unit_price_minor: 3000,
        line_total_minor: 3000
      },
      %{
        id: "018ecb40-c457-73e6-a400-000398daddd7",
        line_no: 1,
        sku_snapshot: "sku-1",
        product_title_snapshot: "Widget 1",
        variant_title_snapshot: "Red",
        quantity: 1,
        unit_price_minor: 1000,
        line_total_minor: 1000
      },
      %{
        id: "018ecb40-c457-73e6-a400-000398daddd8",
        line_no: 2,
        sku_snapshot: "sku-2",
        product_title_snapshot: "Widget 2",
        variant_title_snapshot: "Green",
        quantity: 1,
        unit_price_minor: 2000,
        line_total_minor: 2000
      }
    ]
  end

  defp read_line_items(order_id) do
    OrderLineItem
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false)
    |> Enum.sort_by(& &1.line_no)
  end

  defp read_adjustments(order_id) do
    OrderAdjustment
    |> Ash.Query.filter(expr(order_id == ^order_id))
    |> Ash.read!(domain: Store.Orders, authorize?: false)
    |> Enum.sort_by(& &1.sequence_no)
  end
end
