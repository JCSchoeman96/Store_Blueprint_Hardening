defmodule Store.Payments.RefundsDigitalRevocationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Digital.{DigitalAsset, DownloadGrant, Facade, ProductDigitalLink}
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.{PaymentIntent, WebhookReceipt}
  alias Store.Support.Time
  alias Store.TestFixtures

  setup do
    previous = Application.get_env(:store, :digital, [])

    Application.put_env(
      :store,
      :digital,
      Keyword.merge(previous, refund_revocation_policy: :strict_line_scoped)
    )

    on_exit(fn -> Application.put_env(:store, :digital, previous) end)
    :ok
  end

  test "line-scoped refund success revokes only targeted line grants" do
    %{order: order, payment_intent: payment_intent, line_a: line_a, line_b: line_b} =
      create_paid_order_with_two_digital_lines!()

    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("refund_digital_admin"))
    _admin_role = TestFixtures.assign_role!(admin, :admin)

    assert {:ok, refund} =
             Store.Payments.request_refund(
               %{
                 order_id: order.id,
                 payment_intent_id: payment_intent.id,
                 requested_amount_minor: 1_000,
                 currency: "USD",
                 provider: :stripe,
                 reason: "line-scoped",
                 line_item_ids: [line_a.id],
                 scope_kind: :partial_refund
               },
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    receipt =
      create_refund_webhook_receipt!(
        "stripe",
        %{
          "event_type" => "refund.succeeded",
          "provider_event_id" => "evt_refund_digital_scope_#{System.unique_integer([:positive])}",
          "refund" => %{
            "id" => "re_digital_scope_#{System.unique_integer([:positive])}",
            "idempotency_key" => refund.idempotency_key
          }
        }
      )

    assert :ok = Store.Payments.process_refund_webhook_receipt(receipt)

    assert :revoked == fetch_line_grant!(line_a.id).status
    assert :active == fetch_line_grant!(line_b.id).status
  end

  test "shipping-only refund success does not revoke digital grants" do
    %{order: order, payment_intent: payment_intent, line_a: line_a, line_b: line_b} =
      create_paid_order_with_two_digital_lines!()

    admin =
      TestFixtures.register_user!(
        email: TestFixtures.unique_email("refund_digital_shipping_admin")
      )

    _admin_role = TestFixtures.assign_role!(admin, :admin)

    assert {:ok, refund} =
             Store.Payments.request_refund(
               %{
                 order_id: order.id,
                 payment_intent_id: payment_intent.id,
                 requested_amount_minor: 100,
                 currency: "USD",
                 provider: :stripe,
                 reason: "shipping-only",
                 line_item_ids: [],
                 scope_kind: :shipping_refund
               },
               actor: admin,
               context: %{step_up_at_mono_usec: Time.now_mono_usec()}
             )

    receipt =
      create_refund_webhook_receipt!(
        "stripe",
        %{
          "event_type" => "refund.succeeded",
          "provider_event_id" => "evt_refund_shipping_#{System.unique_integer([:positive])}",
          "refund" => %{
            "id" => "re_refund_shipping_#{System.unique_integer([:positive])}",
            "idempotency_key" => refund.idempotency_key
          }
        }
      )

    assert :ok = Store.Payments.process_refund_webhook_receipt(receipt)

    assert :active == fetch_line_grant!(line_a.id).status
    assert :active == fetch_line_grant!(line_b.id).status
  end

  defp create_paid_order_with_two_digital_lines! do
    customer =
      TestFixtures.register_user!(email: TestFixtures.unique_email("refund_digital_customer"))

    {variant_id, _admin, _product} = published_variant_with_admin!()
    asset = create_digital_asset!()
    _link = create_variant_digital_link!(variant_id, asset.id)

    order = create_order!(customer.id)
    paid_order = mark_order_paid!(order)
    payment_intent = create_succeeded_payment_intent!(paid_order.id, 4_000, "USD")
    line_a = create_order_line_item!(paid_order.id, variant_id, 1)
    line_b = create_order_line_item!(paid_order.id, variant_id, 2)

    assert {:ok, _grants_result} =
             Facade.ensure_paid_order_download_grants_for_system(paid_order.id)

    assert :active == fetch_line_grant!(line_a.id).status
    assert :active == fetch_line_grant!(line_b.id).status

    %{
      order: paid_order,
      payment_intent: payment_intent,
      line_a: line_a,
      line_b: line_b
    }
  end

  defp published_variant_with_admin! do
    admin =
      TestFixtures.register_user!(
        email: TestFixtures.unique_email("refund_digital_catalog_admin")
      )

    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "refund-digital-product-#{System.unique_integer([:positive])}",
          title: "Refund Digital Product",
          base_variant_sku: "REF-DIG-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 2_000,
          base_variant_stock_on_hand: 25
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    {published.default_variant_id, admin, published}
  end

  defp create_order!(user_id) do
    Order
    |> Ash.Changeset.for_create(:create, %{order_ref: unique_order_ref(), user_id: user_id})
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp mark_order_paid!(order) do
    order
    |> Ash.Changeset.for_update(:mark_paid, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp create_succeeded_payment_intent!(order_id, amount_received_minor, currency) do
    intent =
      PaymentIntent
      |> Ash.Changeset.for_create(:create, %{
        order_id: order_id,
        amount_received_minor: amount_received_minor,
        currency: currency,
        provider: :stripe
      })
      |> Ash.create!(domain: Store.Payments, authorize?: false)

    submitted_intent =
      intent
      |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})

    submitted_intent
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp create_order_line_item!(order_id, variant_id, line_no) do
    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      line_no: line_no,
      currency: "USD",
      quantity: 1,
      unit_price_minor: 2_000,
      line_total_minor: 2_000,
      sku_snapshot: "REFUND-DIG-SKU-#{line_no}",
      product_title_snapshot: "Refund Digital Product",
      variant_title_snapshot: "Default",
      variant_id_snapshot: variant_id,
      discount_allocated_minor: 0,
      net_line_total_minor: 2_000
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_digital_asset! do
    DigitalAsset
    |> Ash.Changeset.for_create(:create, %{
      key: "refund-digital-asset-#{System.unique_integer([:positive])}",
      title: "Refund Digital Asset",
      content_type: "application/pdf",
      byte_size: 1024,
      storage_provider: "s3",
      storage_bucket: "downloads-bucket",
      storage_object_key: "assets/refund.pdf",
      status: :active
    })
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_variant_digital_link!(variant_id, asset_id) do
    ProductDigitalLink
    |> Ash.Changeset.for_create(
      :create,
      %{
        variant_id: variant_id,
        digital_asset_id: asset_id,
        position: 0
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_refund_webhook_receipt!(provider, payload) do
    WebhookReceipt
    |> Ash.Changeset.for_create(
      :ingest,
      %{
        provider: provider,
        raw_body: Jason.encode!(payload),
        headers: %{"content-type" => ["application/json"]}
      }
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false)
  end

  defp fetch_line_grant!(line_item_id) do
    assert {:ok, [grant]} =
             DownloadGrant
             |> Ash.Query.filter(expr(order_line_item_id == ^line_item_id))
             |> Ash.read(domain: Store.Digital, authorize?: false, context: %{system?: true})

    grant
  end

  defp unique_order_ref do
    "ORDRFDIG#{System.unique_integer([:positive])}"
  end
end
