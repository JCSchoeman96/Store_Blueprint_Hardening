defmodule Store.Shipping.DomainTest do
  use Store.DataCase, async: false

  alias Store.Shipping
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Support.ID.BinaryUuidSort

  test "same quote request returns stable option ordering and hashes" do
    zone = create_zone!("US", "CA")
    method_alpha = create_method!("ALPHA", "Alpha")
    method_beta = create_method!("BETA", "Beta")
    method_gamma = create_method!("GAMMA", "Gamma")

    _rule_alpha_1 = create_rule!(zone.id, method_alpha.id, 500)
    _rule_alpha_2 = create_rule!(zone.id, method_alpha.id, 500)
    _rule_beta = create_rule!(zone.id, method_beta.id, 500)
    _rule_gamma = create_rule!(zone.id, method_gamma.id, 900)

    request =
      quote_request!(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    assert {:ok, options_first} = Shipping.quote_options(request)
    assert {:ok, options_second} = Shipping.quote_options(request)

    assert options_second == options_first

    assert Enum.map(options_first, & &1.quote_hash) ==
             Enum.map(options_second, & &1.quote_hash)

    assert Enum.map(options_first, &{&1.amount_minor, &1.shipping_method_code}) == [
             {500, "ALPHA"},
             {500, "ALPHA"},
             {500, "BETA"},
             {900, "GAMMA"}
           ]

    alpha_rule_ids =
      options_first
      |> Enum.filter(&(&1.shipping_method_code == "ALPHA"))
      |> Enum.map(& &1.shipping_rule_id)

    assert alpha_rule_ids == BinaryUuidSort.sort_uuids(alpha_rule_ids)
  end

  defp quote_request!(attrs) do
    {:ok, request} = QuoteRequest.new(attrs)
    request
  end

  defp create_zone!(country_code, region_code) do
    code = "ZONE_#{System.unique_integer([:positive])}"

    ShippingZone
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, country_code: country_code, region_code: region_code, active: true},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_method!(code, name) do
    ShippingMethod
    |> Ash.Changeset.for_create(
      :create,
      %{code: code, name: name, active: true, sort_order: 100},
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end

  defp create_rule!(shipping_zone_id, shipping_method_id, shipping_cost_minor) do
    code = "RULE_#{System.unique_integer([:positive])}"

    ShippingRateRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: code,
        shipping_zone_id: shipping_zone_id,
        shipping_method_id: shipping_method_id,
        currency: "USD",
        shipping_cost_minor: shipping_cost_minor,
        active: true,
        precedence_rank: 10
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})
  end
end
