defmodule Store.Governance.PolicyMatrixTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Store.Admin.SiteSetting
  alias Store.Orders.Order
  alias Store.Payments.{PaymentIntent, ProviderEvent, WebhookReceipt}
  alias Store.Support.Time
  alias Store.TestFixtures

  test "customer has own-data access only for orders with matching non-null user_id" do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("customer"))

    other_customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("other_customer"))

    own_order = create_order!(%{user_id: customer.id, order_ref: "ORDOWN001A"})
    other_order = create_order!(%{user_id: other_customer.id, order_ref: "ORDOTH001A"})
    nil_owner_order = create_order!(%{user_id: nil, order_ref: "ORDNIL001A"})

    own_query = Order |> Ash.Query.filter(expr(id == ^own_order.id))
    other_query = Order |> Ash.Query.filter(expr(id == ^other_order.id))
    nil_owner_query = Order |> Ash.Query.filter(expr(id == ^nil_owner_order.id))

    assert {:ok, [result]} = Ash.read(own_query, domain: Store.Orders, actor: customer)
    assert result.id == own_order.id

    assert {:ok, []} = Ash.read(other_query, domain: Store.Orders, actor: customer)
    assert {:ok, []} = Ash.read(nil_owner_query, domain: Store.Orders, actor: customer)

    assert {:ok, customer_orders} = Ash.read(Order, domain: Store.Orders, actor: customer)
    assert Enum.map(customer_orders, & &1.id) == [own_order.id]
  end

  test "admin read scope includes all orders for list and record reads" do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_order_read"))
    _role = TestFixtures.assign_role!(admin, :admin)

    customer_a = TestFixtures.register_user!(email: TestFixtures.unique_email("customer_a"))
    customer_b = TestFixtures.register_user!(email: TestFixtures.unique_email("customer_b"))

    order_a = create_order!(%{user_id: customer_a.id, order_ref: "ORDADM001A"})
    order_b = create_order!(%{user_id: customer_b.id, order_ref: "ORDADM001B"})
    nil_owner_order = create_order!(%{user_id: nil, order_ref: "ORDADM001C"})

    assert {:ok, orders} = Ash.read(Order, domain: Store.Orders, actor: admin)

    assert Enum.sort(Enum.map(orders, & &1.id)) ==
             Enum.sort([order_a.id, order_b.id, nil_owner_order.id])

    assert {:ok, [read_back]} =
             Order
             |> Ash.Query.filter(expr(id == ^nil_owner_order.id))
             |> Ash.read(domain: Store.Orders, actor: admin)

    assert read_back.id == nil_owner_order.id
  end

  test "support cannot mutate provider settings" do
    support = TestFixtures.register_user!(email: TestFixtures.unique_email("support"))
    _role = TestFixtures.assign_role!(support, :support)

    attrs = %{key: :provider_mode, value: %{"mode" => "test"}}

    assert {:error, error} =
             SiteSetting
             |> Ash.Changeset.for_create(:upsert_setting, attrs,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
             |> Ash.create(domain: Store.Admin, actor: support)

    assert Exception.message(error) =~ "forbidden"
  end

  test "support can list orders but cannot read provider evidence resources" do
    support = TestFixtures.register_user!(email: TestFixtures.unique_email("support_read"))
    _role = TestFixtures.assign_role!(support, :support)

    customer_a =
      TestFixtures.register_user!(email: TestFixtures.unique_email("support_customer_a"))

    customer_b =
      TestFixtures.register_user!(email: TestFixtures.unique_email("support_customer_b"))

    order_a = create_order!(%{user_id: customer_a.id, order_ref: "ORDSUP001A"})
    order_b = create_order!(%{user_id: customer_b.id, order_ref: "ORDSUP001B"})

    assert {:ok, support_orders} = Ash.read(Order, domain: Store.Orders, actor: support)
    assert Enum.sort(Enum.map(support_orders, & &1.id)) == Enum.sort([order_a.id, order_b.id])

    provider_event =
      create_provider_event!(%{
        provider: "stripe",
        provider_event_id: "evt_support_scope_001",
        provider_event_key: "stripe:evt_support_scope_001",
        event_type: "payment_intent.succeeded"
      })

    webhook_receipt =
      create_webhook_receipt!(%{
        provider: "stripe",
        idempotency_key: "wh_support_scope_001"
      })

    provider_event_query = ProviderEvent |> Ash.Query.filter(expr(id == ^provider_event.id))
    webhook_receipt_query = WebhookReceipt |> Ash.Query.filter(expr(id == ^webhook_receipt.id))

    assert {:error, provider_event_error} =
             Ash.read(provider_event_query, domain: Store.Payments, actor: support)

    assert Exception.message(provider_event_error) =~ "forbidden"

    assert {:error, webhook_receipt_error} =
             Ash.read(webhook_receipt_query, domain: Store.Payments, actor: support)

    assert Exception.message(webhook_receipt_error) =~ "forbidden"
  end

  test "editor cannot mutate orders, payments, or provider config" do
    editor = TestFixtures.register_user!(email: TestFixtures.unique_email("editor"))
    _role = TestFixtures.assign_role!(editor, :editor)

    order = create_order!(%{user_id: editor.id, order_ref: "ORDEDIT001A"})

    assert {:error, order_error} =
             order
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(domain: Store.Orders, actor: editor)

    assert Exception.message(order_error) =~ "forbidden"

    payment_intent = create_payment_intent!(%{order_id: order.id})

    assert {:error, payment_error} =
             payment_intent
             |> Ash.Changeset.for_update(:submit, %{})
             |> Ash.update(domain: Store.Payments, actor: editor)

    assert Exception.message(payment_error) =~ "forbidden"

    assert {:error, site_setting_error} =
             SiteSetting
             |> Ash.Changeset.for_create(
               :upsert_setting,
               %{key: :provider_mode, value: %{"mode" => "test"}},
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
             |> Ash.create(domain: Store.Admin, actor: editor)

    assert Exception.message(site_setting_error) =~ "forbidden"
  end

  test "admin provider-config mutation requires recent step-up" do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    attrs = %{key: :provider_mode, value: %{"mode" => "test"}}

    assert {:error, no_step_up_error} =
             SiteSetting
             |> Ash.Changeset.for_create(:upsert_setting, attrs, context: %{})
             |> Ash.create(domain: Store.Admin, actor: admin)

    assert Exception.message(no_step_up_error) =~ "forbidden"

    assert {:ok, setting} =
             SiteSetting
             |> Ash.Changeset.for_create(:upsert_setting, attrs,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
             |> Ash.create(domain: Store.Admin, actor: admin)

    assert setting.key == :provider_mode
  end

  test "super_admin provider-config mutation also requires recent step-up" do
    super_admin = TestFixtures.register_user!(email: TestFixtures.unique_email("super_admin"))
    _role = TestFixtures.assign_role!(super_admin, :super_admin)

    attrs = %{key: :provider_display_name, value: %{"name" => "Stripe"}}

    assert {:error, no_step_up_error} =
             SiteSetting
             |> Ash.Changeset.for_create(:upsert_setting, attrs, context: %{})
             |> Ash.create(domain: Store.Admin, actor: super_admin)

    assert Exception.message(no_step_up_error) =~ "forbidden"

    assert {:ok, setting} =
             SiteSetting
             |> Ash.Changeset.for_create(:upsert_setting, attrs,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
             |> Ash.create(domain: Store.Admin, actor: super_admin)

    assert setting.key == :provider_display_name
  end

  test "site setting rejects secret-like payload keys" do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("admin_secret"))
    _role = TestFixtures.assign_role!(admin, :admin)

    assert {:error, error} =
             SiteSetting
             |> Ash.Changeset.for_create(
               :upsert_setting,
               %{key: :provider_mode, value: %{"api_key" => "sk_test_123"}},
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )
             |> Ash.create(domain: Store.Admin, actor: admin)

    assert Exception.message(error) =~ "secret-like"
  end

  test "payment intent reads are denied for non-admin customer actor" do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("customer_pi"))
    payment_intent = create_payment_intent!(%{order_id: nil})

    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent.id))

    assert {:error, error} = Ash.read(query, domain: Store.Payments, actor: customer)
    assert Exception.message(error) =~ "forbidden"
  end

  test "deferred resource checks are resource-aware" do
    deferred_resources = [
      Store.Content.Post,
      Store.Catalog.Product,
      Store.Pricing.PriceBook
    ]

    Enum.each(deferred_resources, fn resource ->
      if Code.ensure_loaded?(resource) do
        flunk(
          "deferred resource #{inspect(resource)} now exists; add explicit phase-06 matrix tests"
        )
      else
        assert true
      end
    end)
  end

  test "orders user_id index exists in postgres" do
    result =
      SQL.query!(
        Store.Repo,
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = 'orders'
          AND indexname = 'orders_user_id_index'
        """,
        []
      )

    assert result.num_rows == 1
  end

  defp create_order!(attrs) do
    Order
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_payment_intent!(attrs) do
    PaymentIntent
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp create_provider_event!(attrs) do
    ProviderEvent
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp create_webhook_receipt!(attrs) do
    attrs =
      attrs
      |> Map.put_new(:raw_body, "{}")
      |> Map.put_new(:headers, %{})

    WebhookReceipt
    |> Ash.Changeset.for_create(:ingest, attrs)
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end
end
