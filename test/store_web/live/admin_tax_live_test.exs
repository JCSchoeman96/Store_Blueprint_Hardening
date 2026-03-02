defmodule StoreWeb.AdminTaxLiveTest do
  use StoreWeb.ConnCase, async: false

  import Ash.Expr
  import Phoenix.LiveViewTest
  require Ash.Query

  alias AshAuthentication.Plug.Helpers
  alias Store.Pricing.TaxRate
  alias Store.Support.Time
  alias Store.TestFixtures

  test "admin with step-up can create a tax rate", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: true)

    {:ok, view, _html} = live(conn, ~p"/admin/tax-rates/new")

    suffix = System.unique_integer([:positive])
    code = "TAX_LV_#{suffix}"

    view
    |> element("#tax-rate-form")
    |> render_submit(%{
      "tax_rate" => %{
        "code" => code,
        "country_code" => "US",
        "region_code" => "CA",
        "product_tax_category" => "STANDARD",
        "rate_basis_points" => "825",
        "shipping_taxable" => "true",
        "active" => "true",
        "starts_at" => "",
        "ends_at" => "",
        "precedence_rank" => "100"
      }
    })

    assert_patch(view, ~p"/admin/tax-rates", 1_000)
    assert render(view) =~ code

    assert {:ok, [tax_rate]} =
             TaxRate
             |> Ash.Query.filter(expr(code == ^code))
             |> Ash.read(domain: Store.Pricing, authorize?: false)

    assert tax_rate.country_code == "US"
  end

  test "admin without step-up is denied tax rate create", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: false)

    {:ok, view, _html} = live(conn, ~p"/admin/tax-rates/new")

    view
    |> element("#tax-rate-form")
    |> render_submit(%{
      "tax_rate" => %{
        "code" => "TAX_LV_DENIED",
        "country_code" => "US",
        "region_code" => "CA",
        "product_tax_category" => "STANDARD",
        "rate_basis_points" => "825",
        "shipping_taxable" => "true",
        "active" => "true",
        "starts_at" => "",
        "ends_at" => "",
        "precedence_rank" => "100"
      }
    })

    assert render(view) =~ "No step-up proof in session. Create/update submit will be denied."
  end

  test "admin with step-up can update a tax rate", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: true)

    suffix = System.unique_integer([:positive])

    tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(:create, %{
        code: "TAX_EDIT_#{suffix}",
        country_code: "US",
        region_code: "CA",
        product_tax_category: "STANDARD",
        rate_basis_points: 700,
        shipping_taxable: true,
        active: true,
        precedence_rank: 100
      })
      |> Ash.create!(domain: Store.Pricing, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/admin/tax-rates/#{tax_rate.id}/edit")

    _html =
      view
      |> element("#tax-rate-form")
      |> render_submit(%{
        "tax_rate" => %{
          "code" => tax_rate.code,
          "country_code" => "US",
          "region_code" => "CA",
          "product_tax_category" => "STANDARD",
          "rate_basis_points" => "900",
          "shipping_taxable" => "true",
          "active" => "true",
          "starts_at" => "",
          "ends_at" => "",
          "precedence_rank" => "100"
        }
      })

    assert {:ok, [updated]} =
             TaxRate
             |> Ash.Query.filter(expr(id == ^tax_rate.id))
             |> Ash.read(domain: Store.Pricing, authorize?: false)

    assert updated.rate_basis_points == 900
  end

  defp signed_in_admin_conn(conn, opts) do
    step_up? = Keyword.get(opts, :step_up?, true)

    admin_email = TestFixtures.unique_email("admin_tax_live")
    _registered_user = TestFixtures.register_user!(email: admin_email)
    admin = TestFixtures.sign_in_user!(admin_email)
    _role = TestFixtures.assign_role!(admin, :admin)

    conn =
      conn
      |> init_test_session(%{})
      |> maybe_put_step_up(step_up?)

    Helpers.store_in_session(conn, admin)
  end

  defp maybe_put_step_up(conn, true),
    do: Plug.Conn.put_session(conn, "step_up_at_mono_usec", Time.now_mono_usec())

  defp maybe_put_step_up(conn, false), do: conn
end
