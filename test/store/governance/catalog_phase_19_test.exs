defmodule Store.Governance.CatalogPhase19Test do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.{Inputs.CartLineInput, InventoryItem, Product, Variant}
  alias Store.TestFixtures

  test "publish/unpublish/archive lifecycle and storefront visibility predicate" do
    admin = admin_actor!()
    product = create_product!(admin, "phase19-lifecycle-a", "P19-LC-001")

    assert product.status == :draft
    assert is_nil(product.published_at)

    assert {:ok, published} =
             product
             |> Ash.Changeset.for_update(:publish, %{})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert published.status == :published
    assert not is_nil(published.published_at)

    assert {:ok, public_products} =
             Product
             |> Ash.Query.for_read(:read_for_public, %{}, actor: nil)
             |> Ash.read(domain: Store.Catalog, actor: nil)

    assert Enum.any?(public_products, &(&1.id == published.id))

    assert {:ok, draft_again} =
             published
             |> Ash.Changeset.for_update(:unpublish, %{})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert draft_again.status == :draft
    assert is_nil(draft_again.published_at)

    assert {:ok, archived} =
             draft_again
             |> Ash.Changeset.for_update(:archive, %{})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert archived.status == :archived

    assert {:error, error} =
             archived
             |> Ash.Changeset.for_update(:publish, %{})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert Exception.message(error) =~ "invalid transition"
  end

  test "slug validation and uniqueness are enforced" do
    admin = admin_actor!()

    assert {:error, invalid_slug_error} =
             Product
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(
                 %{slug: "Not Valid", title: "Invalid"},
                 base_variant_args("P19-SLUG-ERR-1")
               )
             )
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert Exception.message(invalid_slug_error) =~ "slug"

    _product = create_product!(admin, "phase19-slug-a", "P19-SLUG-001")

    assert {:error, duplicate_slug_error} =
             Product
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(
                 %{slug: "phase19-slug-a", title: "Duplicate"},
                 base_variant_args("P19-SLUG-002")
               )
             )
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert Exception.message(duplicate_slug_error) =~ "has already been taken"
  end

  test "variant sku is required and unique" do
    admin = admin_actor!()

    assert {:error, missing_sku_error} =
             Product
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(
                 %{slug: "phase19-missing-sku", title: "Missing SKU"},
                 Map.drop(base_variant_args("P19-MISSING-SKU"), [:base_variant_sku])
               )
             )
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert Exception.message(missing_sku_error) =~ "base_variant_sku"

    _product = create_product!(admin, "phase19-sku-a", "P19-SKU-001")

    assert {:error, duplicate_sku_error} =
             Product
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(
                 %{slug: "phase19-sku-b", title: "SKU duplicate"},
                 base_variant_args("P19-SKU-001")
               )
             )
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert Exception.message(duplicate_sku_error) =~ "has already been taken"
  end

  test "default variant and inventory are created atomically and invariant is enforced" do
    admin = admin_actor!()
    product = create_product!(admin, "phase19-default-a", "P19-DEF-001")

    assert is_binary(product.default_variant_id)

    assert {:ok, [default_variant]} =
             Variant
             |> Ash.Query.filter(expr(product_id == ^product.id and is_default == true))
             |> Ash.read(domain: Store.Catalog, authorize?: false)

    assert default_variant.id == product.default_variant_id

    assert {:ok, [inventory_item]} =
             InventoryItem
             |> Ash.Query.filter(expr(variant_id == ^product.default_variant_id))
             |> Ash.read(domain: Store.Catalog, authorize?: false)

    assert inventory_item.stock_on_hand == 5

    assert {:error, duplicate_default_error} =
             Variant
             |> Ash.Changeset.for_create(
               :create,
               %{
                 product_id: product.id,
                 is_default: true,
                 sku: "P19-DEF-002",
                 currency_code: "USD",
                 price_minor: 1_000
               }
             )
             |> Ash.create(domain: Store.Catalog, actor: admin)

    message = Exception.message(duplicate_default_error)

    assert message =~ "variants_unique_default_per_product_index"
  end

  test "cart line normalization resolves product to variant and rejects mismatches" do
    admin = admin_actor!()
    product_a = create_product!(admin, "phase19-cartline-a", "P19-CART-001")
    product_b = create_product!(admin, "phase19-cartline-b", "P19-CART-002")

    assert {:ok, normalized_from_product} =
             CartLineInput.new(%{"product_id" => product_a.id, "quantity" => 2})

    assert normalized_from_product.variant_id == product_a.default_variant_id
    assert normalized_from_product.quantity == 2

    assert {:ok, normalized_from_variant} =
             CartLineInput.new(%{"variant_id" => product_a.default_variant_id, "quantity" => 1})

    assert normalized_from_variant.variant_id == product_a.default_variant_id

    assert {:ok, _matching_both} =
             CartLineInput.new(%{
               "product_id" => product_a.id,
               "variant_id" => product_a.default_variant_id,
               "quantity" => 1
             })

    assert {:error, mismatch_error} =
             CartLineInput.new(%{
               "product_id" => product_a.id,
               "variant_id" => product_b.default_variant_id,
               "quantity" => 1
             })

    assert mismatch_error.code == "VALIDATION_ERROR"
  end

  defp admin_actor! do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("catalog_admin"))
    _role = TestFixtures.assign_role!(user, :admin)
    user
  end

  defp create_product!(admin, slug, sku) do
    Product
    |> Ash.Changeset.for_create(
      :create_draft,
      Map.merge(%{slug: slug, title: "Catalog #{slug}"}, base_variant_args(sku))
    )
    |> Ash.create!(domain: Store.Catalog, actor: admin)
  end

  defp base_variant_args(sku) do
    %{
      base_variant_sku: sku,
      base_variant_currency_code: "USD",
      base_variant_price_minor: 1_500,
      base_variant_stock_on_hand: 5
    }
  end
end
