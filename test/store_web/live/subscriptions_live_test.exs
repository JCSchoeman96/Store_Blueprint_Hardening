defmodule StoreWeb.SubscriptionsLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_live_subscriptions",
        publishable_key: "pk_test_live_subscriptions",
        request_options: StripeAPIStub.req_options()
      ]
    )

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "account subscription detail queues plan changes inline and opens the card-update modal",
       %{
         conn: conn
       } do
    customer = signed_in_user(TestFixtures.unique_email("account_subscription_live"))
    conn = authenticated_conn(conn, customer)

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "live-current",
        name: "Live Current",
        amount_minor: 1_500
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "live-target",
        name: "Live Target",
        amount_minor: 2_500
      })

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_live_account_001",
        provider_billing_ref: "pm_live_account_001"
      })

    {:ok, view, html} = live(conn, ~p"/account/subscriptions/#{subscription.id}")

    assert html =~ "Current Renewal Price"
    assert html =~ "Update Card"

    updated_html =
      view
      |> form("form[phx-submit=\"queue_plan_change\"]", %{
        "queue_subscription_plan_change" => %{"subscription_plan_id" => target_plan.id}
      })
      |> render_submit()

    assert updated_html =~ "Plan change queued for the next successful renewal"
    assert updated_html =~ "USD 25.00"

    modal_html =
      view
      |> element("button[phx-click=\"start_payment_method_update\"]")
      |> render_click()

    assert modal_html =~ "pk_test_live_subscriptions"
    assert modal_html =~ "phx-hook=\"StripeElements\""
    assert modal_html =~ "Save Card"
  end

  test "admin subscription detail renders support-grade billing refs and queued-action controls",
       %{
         conn: conn
       } do
    admin = signed_in_user(TestFixtures.unique_email("admin_subscription_live"))
    _role = TestFixtures.assign_role!(admin, :admin)
    conn = authenticated_conn(conn, admin)

    customer = SubscriptionsFixtures.create_customer!("admin_subscription_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "admin-current",
        name: "Admin Current",
        amount_minor: 1_500
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "admin-target",
        name: "Admin Target",
        amount_minor: 2_500
      })

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_admin_live_001",
        provider_billing_ref: "pm_admin_live_001"
      })

    {:ok, _view, html} = live(conn, ~p"/admin/subscriptions/#{subscription.id}")

    assert html =~ "Provider Customer Ref"
    assert html =~ "cus_admin_live_001"
    assert html =~ "Provider Billing Ref"
    assert html =~ "pm_admin_live_001"
    assert html =~ "Queue Plan Change"
    assert html =~ "Queue Variant Change"
    assert html =~ "Update Card"
  end

  test "authenticated non-admin is redirected away from admin subscriptions routes", %{conn: conn} do
    customer = signed_in_user(TestFixtures.unique_email("customer_admin_subscriptions_live"))
    conn = authenticated_conn(conn, customer)

    customer_record = SubscriptionsFixtures.create_customer!("non_admin_subscription_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "non-admin-check",
        name: "Non Admin Check",
        amount_minor: 1_500
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer_record.id, variant, plan, %{
        provider: :stripe
      })

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/subscriptions")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/admin/subscriptions/#{subscription.id}")
  end

  test "subscriptions index reacts to entitlement invalidation with a pushed event", %{conn: conn} do
    customer = signed_in_user(TestFixtures.unique_email("subscription_entitlement_live"))
    conn = authenticated_conn(conn, customer)

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "membership-live",
        name: "Membership Live",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:live"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe
      })

    assert {:ok, _grant} =
             EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)

    {:ok, view, html} = live(conn, ~p"/account/subscriptions")

    assert html =~ "membership:live"

    assert {:ok, _revoked_count} =
             EntitlementsFacade.revoke_subscription_entitlements_for_system(
               subscription.id,
               "grace_expired"
             )

    assert_push_event(view, "membership_expired", %{reason: "grace_expired"})
    assert render(view) =~ "No active entitlements."
  end

  defp authenticated_conn(conn, user) do
    conn
    |> init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp signed_in_user(email) do
    _registered = TestFixtures.register_user!(email: email)
    TestFixtures.sign_in_user!(email)
  end
end
