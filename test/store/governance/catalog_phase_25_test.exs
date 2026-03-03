defmodule Store.Governance.CatalogPhase25Test do
  use Store.DataCase, async: false

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput

  alias Store.Catalog.{
    InventoryItem,
    Product,
    ProductOption,
    ProductOptionValue,
    Variant,
    VariantOptionSelection
  }

  alias Store.Catalog.Facade, as: CatalogFacade
  alias Store.Catalog.VariantResolver
  alias Store.Repo
  alias Store.TestFixtures

  test "active variant requires required option completeness" do
    admin = admin_actor!()
    product = published_product!(admin, "phase25-required", "P25-REQ-BASE")

    size_option = create_option!(admin, product.id, "Size", "size", 0, true)
    medium = create_value!(admin, size_option.id, "Medium", "m", 0)

    assert {:error, error} =
             Variant
             |> Ash.Changeset.for_create(:create, %{
               product_id: product.id,
               sku: "P25-REQ-ACTIVE-FAIL",
               currency_code: "USD",
               price_minor: 2_500,
               status: :active
             })
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert Exception.message(error) =~ "required option selections"

    assert {:ok, archived_variant} =
             Variant
             |> Ash.Changeset.for_create(:create, %{
               product_id: product.id,
               sku: "P25-REQ-ARCH-OK",
               currency_code: "USD",
               price_minor: 2_500,
               status: :archived
             })
             |> Ash.create(domain: Store.Catalog, actor: admin)

    _inventory = create_inventory!(admin, archived_variant.id, 25)

    assert {:ok, _selection} =
             VariantOptionSelection
             |> Ash.Changeset.for_create(:create, %{
               variant_id: archived_variant.id,
               product_option_id: size_option.id,
               product_option_value_id: medium.id
             })
             |> Ash.create(domain: Store.Catalog, actor: admin)

    assert {:ok, active_variant} =
             archived_variant
             |> Ash.Changeset.for_update(:update, %{status: :active})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    active_variant = Repo.get!(Variant, active_variant.id)

    assert is_binary(active_variant.selection_signature)
    assert byte_size(active_variant.selection_signature) == 32
  end

  test "resolver handles optional omission ambiguity and out-of-stock" do
    admin = admin_actor!()
    product = published_product!(admin, "phase25-optional", "P25-OPT-BASE")

    size_option = create_option!(admin, product.id, "Size", "size", 0, true)
    color_option = create_option!(admin, product.id, "Color", "color", 1, false)

    medium = create_value!(admin, size_option.id, "Medium", "m", 0)
    red = create_value!(admin, color_option.id, "Red", "red", 0)
    blue = create_value!(admin, color_option.id, "Blue", "blue", 1)

    red_variant = create_variant!(admin, product.id, "P25-OPT-RED", :archived)
    blue_variant = create_variant!(admin, product.id, "P25-OPT-BLUE", :archived)

    _inv_red = create_inventory!(admin, red_variant.id, 5)
    _inv_blue = create_inventory!(admin, blue_variant.id, 5)

    _ = set_selection!(admin, red_variant.id, size_option.id, medium.id)
    _ = set_selection!(admin, red_variant.id, color_option.id, red.id)
    _ = set_selection!(admin, blue_variant.id, size_option.id, medium.id)
    _ = set_selection!(admin, blue_variant.id, color_option.id, blue.id)

    assert {:ok, _} =
             red_variant
             |> Ash.Changeset.for_update(:update, %{status: :active})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert {:ok, _} =
             blue_variant
             |> Ash.Changeset.for_update(:update, %{status: :active})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    assert {:ok, detail_ambiguous} =
             VariantResolver.build_product_detail(product, %{"size" => "m"})

    assert detail_ambiguous.resolution.status == :error
    assert detail_ambiguous.resolution.reason == :selection_ambiguous

    assert {:ok, detail_resolved} =
             VariantResolver.build_product_detail(product, %{"size" => "m", "color" => "red"})

    assert detail_resolved.resolution.status == :ok
    assert detail_resolved.resolution.variant_id == red_variant.id

    inventory_red = inventory_by_variant!(red_variant.id)

    assert {:ok, _updated_inventory} =
             inventory_red
             |> Ash.Changeset.for_update(:set_on_hand, %{stock_on_hand: 0, allow_oversell: false})
             |> Ash.update(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    assert {:ok, detail_oos} =
             VariantResolver.build_product_detail(product, %{"size" => "m", "color" => "red"})

    assert detail_oos.resolution.status == :error
    assert detail_oos.resolution.reason == :out_of_stock
  end

  test "selection signature is deterministic regardless of assignment order" do
    admin = admin_actor!()
    product = published_product!(admin, "phase25-signature", "P25-SIG-BASE")

    size_option = create_option!(admin, product.id, "Size", "size", 0, true)
    color_option = create_option!(admin, product.id, "Color", "color", 1, true)

    medium = create_value!(admin, size_option.id, "Medium", "m", 0)
    red = create_value!(admin, color_option.id, "Red", "red", 0)

    variant_a = create_variant!(admin, product.id, "P25-SIG-A", :archived)
    _inv_a = create_inventory!(admin, variant_a.id, 3)

    _ = set_selection!(admin, variant_a.id, color_option.id, red.id)
    _ = set_selection!(admin, variant_a.id, size_option.id, medium.id)

    assert {:ok, _active_a} =
             variant_a
             |> Ash.Changeset.for_update(:update, %{status: :active})
             |> Ash.update(domain: Store.Catalog, actor: admin)

    variant_b = create_variant!(admin, product.id, "P25-SIG-B", :archived)
    _inv_b = create_inventory!(admin, variant_b.id, 3)

    _ = set_selection!(admin, variant_b.id, size_option.id, medium.id)
    _ = set_selection!(admin, variant_b.id, color_option.id, red.id)

    assert {:error, error} =
             CatalogFacade.update_variant_for_admin(admin, variant_b.id, %{status: :active})

    assert error.code == "VALIDATION_ERROR"
  end

  test "cart stock pre-check blocks qty above fast sellable qty" do
    admin = admin_actor!()
    published = published_product!(admin, "phase25-cart", "P25-CART-BASE")
    variant_id = published.default_variant_id
    inventory = inventory_by_variant!(variant_id)

    assert {:ok, _updated_inventory} =
             inventory
             |> Ash.Changeset.for_update(:set_on_hand, %{stock_on_hand: 1, allow_oversell: false})
             |> Ash.update(domain: Store.Catalog, authorize?: false, context: %{system?: true})

    token = Ash.UUIDv7.generate()

    assert {:ok, input_add} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 1})
    assert {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, input_add)

    assert {:ok, input_update} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:error, error} = CartsFacade.update_item_qty_for_user(nil, token, input_update)
    assert error.code == "OUT_OF_STOCK"
  end

  defp admin_actor! do
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("catalog_phase25_admin"))
    _role = TestFixtures.assign_role!(user, :admin)
    user
  end

  defp published_product!(admin, slug, sku) do
    product =
      Product
      |> Ash.Changeset.for_create(:create_draft, %{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        title: "Phase 25 #{slug}",
        base_variant_sku: "#{sku}-#{System.unique_integer([:positive])}",
        base_variant_currency_code: "USD",
        base_variant_price_minor: 2_000,
        base_variant_stock_on_hand: 10
      })
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    product
    |> Ash.Changeset.for_update(:publish, %{})
    |> Ash.update!(domain: Store.Catalog, actor: admin)
  end

  defp create_option!(admin, product_id, name, slug, position, required?) do
    ProductOption
    |> Ash.Changeset.for_create(:create, %{
      product_id: product_id,
      name: name,
      slug: slug,
      position: position,
      selection_required: required?
    })
    |> Ash.create!(domain: Store.Catalog, actor: admin)
  end

  defp create_value!(admin, option_id, name, slug, position) do
    ProductOptionValue
    |> Ash.Changeset.for_create(:create, %{
      product_option_id: option_id,
      name: name,
      slug: slug,
      position: position
    })
    |> Ash.create!(domain: Store.Catalog, actor: admin)
  end

  defp create_variant!(admin, product_id, sku, status) do
    Variant
    |> Ash.Changeset.for_create(:create, %{
      product_id: product_id,
      sku: "#{sku}-#{System.unique_integer([:positive])}",
      currency_code: "USD",
      price_minor: 2_500,
      status: status
    })
    |> Ash.create!(domain: Store.Catalog, actor: admin)
  end

  defp create_inventory!(_admin, variant_id, stock_on_hand) do
    InventoryItem
    |> Ash.Changeset.for_create(:create, %{
      variant_id: variant_id,
      stock_on_hand: stock_on_hand,
      reserved_count: 0,
      allow_oversell: false
    })
    |> Ash.create!(domain: Store.Catalog, authorize?: false, context: %{system?: true})
  end

  defp set_selection!(admin, variant_id, option_id, value_id) do
    VariantOptionSelection
    |> Ash.Changeset.for_create(:create, %{
      variant_id: variant_id,
      product_option_id: option_id,
      product_option_value_id: value_id
    })
    |> Ash.create!(domain: Store.Catalog, actor: admin)
  end

  defp inventory_by_variant!(variant_id) do
    Repo.get_by!(InventoryItem, variant_id: variant_id)
  end
end
