defmodule StoreWeb.AdminShippingLiveTest do
  use StoreWeb.ConnCase, async: false

  import Ash.Expr
  import Phoenix.LiveViewTest
  require Ash.Query

  alias AshAuthentication.Plug.Helpers
  alias Store.Pricing.{ShippingRate, ShippingZone}
  alias Store.Support.Time
  alias Store.TestFixtures

  test "admin with step-up can create a shipping zone", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: true)

    {:ok, view, _html} = live(conn, ~p"/admin/shipping-zones")

    view |> element("#new-shipping-zone") |> render_click()
    assert render(view) =~ "Create Shipping Zone"

    suffix = System.unique_integer([:positive])
    code = "ZONE_LV_#{suffix}"

    view
    |> element("#shipping-zone-form")
    |> render_submit(%{
      "shipping_zone" => %{
        "code" => code,
        "country_code" => "US",
        "region_code" => "CA",
        "active" => "true"
      }
    })

    assert_patch(view, ~p"/admin/shipping-zones")
    assert render(view) =~ code

    assert {:ok, [zone]} =
             ShippingZone
             |> Ash.Query.filter(expr(code == ^code))
             |> Ash.read(domain: Store.Pricing, authorize?: false)

    assert zone.country_code == "US"
  end

  test "admin without step-up is denied shipping zone create", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: false)

    {:ok, view, _html} = live(conn, ~p"/admin/shipping-zones/new")

    view
    |> element("#shipping-zone-form")
    |> render_submit(%{
      "shipping_zone" => %{
        "code" => "ZONE_LV_DENIED",
        "country_code" => "US",
        "region_code" => "CA",
        "active" => "true"
      }
    })

    assert render(view) =~ "No step-up proof in session. Create/update submit will be denied."
  end

  test "shipping rate form renders resource validation errors", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: true)

    {:ok, view, _html} = live(conn, ~p"/admin/shipping-rates/new")

    html =
      view
      |> element("#shipping-rate-form")
      |> render_submit(%{
        "shipping_rate" => %{
          "code" => "RATE_LV_INVALID",
          "currency" => "USD",
          "shipping_zone_id" => "",
          "shipping_cost_minor" => "1000",
          "weight_min_grams" => "100",
          "weight_max_grams" => "10",
          "free_over_subtotal_minor" => "",
          "allow_free_shipping_coupon" => "false",
          "active" => "true",
          "starts_at" => "",
          "ends_at" => "",
          "precedence_rank" => "100"
        }
      })

    assert html =~ "must be greater than or equal to weight_min_grams"
  end

  test "admin with step-up can create a shipping rate", %{conn: conn} do
    conn = signed_in_admin_conn(conn, step_up?: true)

    {:ok, view, _html} = live(conn, ~p"/admin/shipping-rates/new")

    suffix = System.unique_integer([:positive])
    code = "RATE_LV_#{suffix}"

    view
    |> element("#shipping-rate-form")
    |> render_submit(%{
      "shipping_rate" => %{
        "code" => code,
        "currency" => "USD",
        "shipping_zone_id" => "",
        "shipping_cost_minor" => "1500",
        "weight_min_grams" => "",
        "weight_max_grams" => "",
        "free_over_subtotal_minor" => "",
        "allow_free_shipping_coupon" => "false",
        "active" => "true",
        "starts_at" => "",
        "ends_at" => "",
        "precedence_rank" => "100"
      }
    })

    assert_patch(view, ~p"/admin/shipping-rates")
    assert render(view) =~ code

    assert {:ok, [rate]} =
             ShippingRate
             |> Ash.Query.filter(expr(code == ^code))
             |> Ash.read(domain: Store.Pricing, authorize?: false)

    assert rate.currency == "USD"
  end

  defp signed_in_admin_conn(conn, opts) do
    step_up? = Keyword.get(opts, :step_up?, true)

    admin_email = TestFixtures.unique_email("admin_shipping_live")
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
