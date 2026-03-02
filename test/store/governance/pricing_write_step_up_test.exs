defmodule Store.Governance.PricingWriteStepUpTest do
  use Store.DataCase, async: false

  alias Store.Admin.Authorization
  alias Store.Pricing.{ShippingRate, ShippingZone, TaxRate}
  alias Store.Support.Time
  alias Store.TestFixtures

  test "admin create shipping zone requires step-up" do
    admin = admin_actor()
    assert Authorization.has_any_role?(admin, [:admin])

    assert {:error, error} =
             ShippingZone
             |> Ash.Changeset.for_create(:create, shipping_zone_attrs())
             |> Ash.create(domain: Store.Pricing, actor: admin)

    assert Exception.message(error) =~ "forbidden"

    assert {:ok, zone} =
             ShippingZone
             |> Ash.Changeset.for_create(:create, shipping_zone_attrs())
             |> Ash.create(domain: Store.Pricing, actor: admin, context: step_up_context())

    assert zone.code =~ "ZONE_"
  end

  test "admin update tax rate requires step-up" do
    admin = admin_actor()
    assert Authorization.has_any_role?(admin, [:admin])

    tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(:create, tax_rate_attrs())
      |> Ash.create!(domain: Store.Pricing, authorize?: false)

    assert {:error, error} =
             tax_rate
             |> Ash.Changeset.for_update(:update, %{rate_basis_points: 900})
             |> Ash.update(domain: Store.Pricing, actor: admin)

    assert Exception.message(error) =~ "forbidden"

    assert {:ok, updated} =
             tax_rate
             |> Ash.Changeset.for_update(:update, %{rate_basis_points: 900})
             |> Ash.update(domain: Store.Pricing, actor: admin, context: step_up_context())

    assert updated.rate_basis_points == 900
  end

  test "support cannot create shipping rate even with step-up context" do
    support = support_actor()

    assert {:error, error} =
             ShippingRate
             |> Ash.Changeset.for_create(:create, shipping_rate_attrs())
             |> Ash.create(domain: Store.Pricing, actor: support, context: step_up_context())

    assert Exception.message(error) =~ "forbidden"
  end

  test "customer cannot create tax rate with step-up context" do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("customer_pricing_write"))

    assert {:error, error} =
             TaxRate
             |> Ash.Changeset.for_create(:create, tax_rate_attrs())
             |> Ash.create(domain: Store.Pricing, actor: customer, context: step_up_context())

    assert Exception.message(error) =~ "forbidden"
  end

  defp admin_actor do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_pricing_write"))
    _role = TestFixtures.assign_role!(user, :admin)
    user
  end

  defp support_actor do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("support_pricing_write"))
    _role = TestFixtures.assign_role!(user, :support)
    user
  end

  defp shipping_zone_attrs do
    suffix = System.unique_integer([:positive])
    %{code: "ZONE_#{suffix}", country_code: "US", region_code: "CA", active: true}
  end

  defp shipping_rate_attrs do
    suffix = System.unique_integer([:positive])

    %{
      code: "RATE_#{suffix}",
      currency: "USD",
      shipping_cost_minor: 1000,
      active: true,
      precedence_rank: 100
    }
  end

  defp tax_rate_attrs do
    suffix = System.unique_integer([:positive])

    %{
      code: "TAX_#{suffix}",
      country_code: "US",
      region_code: nil,
      product_tax_category: "STANDARD",
      rate_basis_points: 825,
      shipping_taxable: true,
      active: true,
      precedence_rank: 100
    }
  end

  defp step_up_context do
    %{step_up_at_mono_usec: Time.now_mono_usec()}
  end
end
