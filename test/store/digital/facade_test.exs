defmodule Store.Digital.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Digital.{DigitalAsset, DownloadGrant, Facade, ProductDigitalLink}
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.TestFixtures

  setup do
    previous_rate_limit = Application.get_env(:store, :rate_limit, [])

    Application.put_env(
      :store,
      :rate_limit,
      Keyword.merge(previous_rate_limit,
        signed_download_limit: 1,
        signed_download_window_seconds: 300
      )
    )

    case :ets.whereis(:store_rate_limit) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    on_exit(fn ->
      Application.put_env(:store, :rate_limit, previous_rate_limit)

      case :ets.whereis(:store_rate_limit) do
        :undefined -> :ok
        table -> :ets.delete(table)
      end
    end)

    :ok
  end

  test "grant issuance is idempotent and variant links win duplicate product links" do
    %{order: order, line_item: line_item, variant_id: variant_id} =
      create_paid_order_line_fixture!()

    asset_a = create_digital_asset!("asset-a")
    asset_b = create_digital_asset!("asset-b")

    _product_link_a =
      create_product_digital_link!(%{
        product_id: fetch_variant!(variant_id).product_id,
        digital_asset_id: asset_a.id,
        position: 1,
        grant_max_downloads: 2
      })

    _product_link_b =
      create_product_digital_link!(%{
        product_id: fetch_variant!(variant_id).product_id,
        digital_asset_id: asset_b.id,
        position: 0,
        grant_max_downloads: 2
      })

    _variant_link_b =
      create_product_digital_link!(%{
        variant_id: variant_id,
        digital_asset_id: asset_b.id,
        position: 5,
        grant_max_downloads: 7
      })

    parent = self()
    handler_id = {__MODULE__, :grant_issued, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:store, :digital, :grant_issued],
      fn _event, measurements, metadata, pid ->
        send(pid, {:grant_issued, measurements, metadata})
      end,
      parent
    )

    try do
      assert {:ok, %{processed_count: 2}} =
               Facade.ensure_paid_order_download_grants_for_system(order.id)

      assert_receive {:grant_issued, %{count: 1}, first_metadata}
      assert_receive {:grant_issued, %{count: 1}, second_metadata}
      assert first_metadata.order_id == order.id
      assert second_metadata.order_id == order.id

      assert {:ok, %{processed_count: 2}} =
               Facade.ensure_paid_order_download_grants_for_system(order.id)

      refute_receive {:grant_issued, _measurements, _metadata}, 100

      grants = fetch_grants_for_line_item!(line_item.id)
      assert length(grants) == 2

      assert Enum.any?(grants, fn grant -> grant.digital_asset_id == asset_a.id end)

      asset_b_grant =
        Enum.find(grants, fn grant -> grant.digital_asset_id == asset_b.id end)

      assert asset_b_grant.max_downloads == 7
    after
      :telemetry.detach(handler_id)
    end
  end

  test "signed URL issuance validates grant state and applies rate limiting" do
    %{order: order, line_item: line_item, user: user, variant_id: variant_id} =
      create_paid_order_line_fixture!()

    asset = create_digital_asset!("asset-download")
    asset_expiring = create_digital_asset!("asset-expiring")

    _variant_link =
      create_product_digital_link!(%{
        variant_id: variant_id,
        digital_asset_id: asset.id,
        position: 0
      })

    _variant_link_expiring =
      create_product_digital_link!(%{
        variant_id: variant_id,
        digital_asset_id: asset_expiring.id,
        position: 1
      })

    assert {:ok, _result} = Facade.ensure_paid_order_download_grants_for_system(order.id)
    grants = fetch_grants_for_line_item!(line_item.id)
    grant = Enum.find(grants, fn value -> value.digital_asset_id == asset.id end)

    expiring_grant =
      Enum.find(grants, fn value -> value.digital_asset_id == asset_expiring.id end)

    assert {:ok, %{signed_url: signed_url}} =
             Facade.issue_signed_download_url_for_user(user, grant.id)

    assert String.starts_with?(signed_url, "https://")

    assert {:error, rate_limited} =
             Facade.issue_signed_download_url_for_user(user, grant.id)

    assert rate_limited.code == "DIGITAL_DOWNLOAD_RATE_LIMITED"

    revoked_grant = revoke_grant!(grant.id)

    assert {:error, revoked_error} =
             Facade.issue_signed_download_url_for_user(user, revoked_grant.id)

    assert revoked_error.code == "DIGITAL_GRANT_REVOKED"

    expired_grant = expire_grant!(expiring_grant.id)

    assert {:error, expired_error} =
             Facade.issue_signed_download_url_for_user(user, expired_grant.id)

    assert expired_error.code == "DIGITAL_GRANT_EXPIRED"
  end

  defp create_paid_order_line_fixture! do
    customer = TestFixtures.register_user!(email: TestFixtures.unique_email("digital_customer"))
    {variant_id, _admin, _product} = published_variant_with_admin!()
    order = create_order!(customer.id)
    paid_order = mark_order_paid!(order)
    line_item = create_order_line_item!(paid_order.id, variant_id, 1)

    %{user: customer, order: paid_order, line_item: line_item, variant_id: variant_id}
  end

  defp published_variant_with_admin! do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("digital_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "digital-product-#{System.unique_integer([:positive])}",
          title: "Digital Product",
          base_variant_sku: "DIG-#{System.unique_integer([:positive])}",
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

  defp create_order_line_item!(order_id, variant_id, line_no) do
    OrderLineItem
    |> Ash.Changeset.for_create(:create, %{
      order_id: order_id,
      line_no: line_no,
      currency: "USD",
      quantity: 1,
      unit_price_minor: 2_000,
      line_total_minor: 2_000,
      sku_snapshot: "DIG-SKU-#{line_no}",
      product_title_snapshot: "Digital Product",
      variant_title_snapshot: "Default",
      variant_id_snapshot: variant_id,
      discount_allocated_minor: 0,
      net_line_total_minor: 2_000
    })
    |> Ash.create!(domain: Store.Orders, authorize?: false)
  end

  defp create_digital_asset!(key) do
    DigitalAsset
    |> Ash.Changeset.for_create(:create, %{
      key: "#{key}-#{System.unique_integer([:positive])}",
      title: "Asset #{key}",
      content_type: "application/pdf",
      byte_size: 1024,
      storage_provider: "s3",
      storage_bucket: "downloads-bucket",
      storage_object_key: "assets/#{key}.pdf",
      status: :active
    })
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp create_product_digital_link!(attrs) do
    ProductDigitalLink
    |> Ash.Changeset.for_create(:create, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp fetch_grants_for_line_item!(line_item_id) do
    assert {:ok, grants} =
             DownloadGrant
             |> Ash.Query.filter(expr(order_line_item_id == ^line_item_id))
             |> Ash.read(domain: Store.Digital, authorize?: false, context: %{system?: true})

    grants
  end

  defp revoke_grant!(grant_id) do
    [grant] = fetch_grants_for_id!(grant_id)

    grant
    |> Ash.Changeset.for_update(:revoke, %{revoked_reason: "test"}, context: %{system?: true})
    |> Ash.update!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp expire_grant!(grant_id) do
    [grant] = fetch_grants_for_id!(grant_id)

    grant
    |> Ash.Changeset.for_update(:expire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Digital, authorize?: false, context: %{system?: true})
  end

  defp fetch_grants_for_id!(grant_id) do
    assert {:ok, grants} =
             DownloadGrant
             |> Ash.Query.filter(expr(id == ^grant_id))
             |> Ash.read(domain: Store.Digital, authorize?: false, context: %{system?: true})

    grants
  end

  defp fetch_variant!(variant_id) do
    assert {:ok, [variant]} =
             Store.Catalog.Variant
             |> Ash.Query.filter(expr(id == ^variant_id))
             |> Ash.read(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    variant
  end

  defp unique_order_ref do
    "ORDDIG#{System.unique_integer([:positive])}"
  end
end
