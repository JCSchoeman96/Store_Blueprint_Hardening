defmodule Store.Carts.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Carts.{Cart, Facade}
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Carts.Queries.CartLoadQuery
  alias Store.Checkout
  alias Store.Checkout.Inputs.CheckoutStartInput
  alias Store.Orders.Order
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures

  setup do
    previous_flags = Application.get_env(:store, :subscription_features, [])

    on_exit(fn ->
      Application.put_env(:store, :subscription_features, previous_flags)
    end)

    :ok
  end

  test "lookup rule prefers user active cart for authenticated actor" do
    token = Ash.UUIDv7.generate()
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("cart_user_lookup"))

    assert {:ok, guest_cart} = Facade.get_cart_for_user(nil, token)
    assert is_nil(guest_cart.user_id)
    assert guest_cart.token == token

    assert {:ok, user_cart} = Facade.get_cart_for_user(user, token)
    assert user_cart.user_id == user.id
    assert user_cart.id != guest_cart.id

    assert {:ok, loaded_again} = Facade.get_cart_for_user(user, token)
    assert loaded_again.id == user_cart.id
  end

  test "cart version increments on add/update/remove and not on noop updates" do
    token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()

    assert {:ok, cart} = Facade.get_cart_for_user(nil, token)
    assert cart.version == 1

    assert {:ok, input_add} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, cart_after_add} = Facade.add_item_for_user(nil, token, input_add)
    assert cart_after_add.version == 2

    assert {:ok, input_update} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 4})
    assert {:ok, cart_after_update} = Facade.update_item_qty_for_user(nil, token, input_update)
    assert cart_after_update.version == 3

    assert {:ok, cart_after_noop} = Facade.update_item_qty_for_user(nil, token, input_update)
    assert cart_after_noop.version == 3

    assert {:ok, cart_after_remove} = Facade.remove_item_for_user(nil, token, variant_id)
    assert cart_after_remove.version == 4
  end

  test "guest to user merge is deterministic and idempotent" do
    token = Ash.UUIDv7.generate()
    variant_id = published_variant_id!()
    user = TestFixtures.register_user!(email: TestFixtures.unique_email("cart_merge_user"))

    assert {:ok, add_guest} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 2})
    assert {:ok, _guest_cart} = Facade.add_item_for_user(nil, token, add_guest)

    assert {:ok, add_user} = CartItemInput.new(%{"variant_id" => variant_id, "qty" => 3})
    assert {:ok, _user_cart} = Facade.add_item_for_user(user, token, add_user)

    assert {:ok, :merged} = Facade.merge_token_into_user_for_user(user, token)

    assert {:ok, query} = CartLoadQuery.new(%{"include_items" => true})
    assert {:ok, user_view} = Facade.get_cart_view_for_user(user, token, query)
    assert [%{qty: 5}] = Enum.filter(user_view.items, &(&1.variant_id == variant_id))

    assert {:ok, :noop} = Facade.merge_token_into_user_for_user(user, token)

    guest_cart =
      Cart
      |> Repo.get_by!(token: token)

    assert guest_cart.status == :abandoned
    assert is_binary(guest_cart.merged_into_cart_id)
  end

  test "membership add-to-cart is blocked when the user already has an active membership" do
    enable_subscription_purchase!()

    user = SubscriptionsFixtures.create_customer!("cart_membership_active")
    token = Ash.UUIDv7.generate()
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:cart-active"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    _existing = SubscriptionsFixtures.create_subscription_fixture!(user.id, variant, plan)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:error, error} = Facade.add_item_for_user(user, token, add_input)
    assert error.code == "SUBSCRIPTION_DUPLICATE"
  end

  test "membership add-to-cart is blocked when a pending membership checkout already exists" do
    enable_subscription_purchase!()

    user = SubscriptionsFixtures.create_customer!("cart_membership_pending")
    token = Ash.UUIDv7.generate()
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:cart-pending"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = Facade.add_item_for_user(user, token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, _started} = Checkout.start_from_cart(user, token, start_input)

    assert {:error, error} = Facade.add_item_for_user(user, token, add_input)
    assert error.code == "SUBSCRIPTION_DUPLICATE"
  end

  test "membership add-to-cart is blocked when the user already has a past-due membership" do
    enable_subscription_purchase!()

    user = SubscriptionsFixtures.create_customer!("cart_membership_past_due")
    token = Ash.UUIDv7.generate()
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:cart-past-due"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    _existing =
      SubscriptionsFixtures.create_subscription_fixture!(user.id, variant, plan, %{
        status: :past_due,
        billing_status_reason: "PAYMENT_FAILED",
        next_retry_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:error, error} = Facade.add_item_for_user(user, token, add_input)
    assert error.code == "SUBSCRIPTION_DUPLICATE"
  end

  test "membership pending-order guard stops blocking once the prior order is no longer collectible" do
    enable_subscription_purchase!()

    user = SubscriptionsFixtures.create_customer!("cart_membership_terminal_pending")
    first_token = Ash.UUIDv7.generate()
    second_token = Ash.UUIDv7.generate()
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:cart-terminal-pending"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    assert {:ok, add_input} =
             CartItemInput.new(%{
               "variant_id" => variant.id,
               "subscription_plan_id" => plan.id,
               "qty" => 1
             })

    assert {:ok, _cart} = Facade.add_item_for_user(user, first_token, add_input)
    assert {:ok, start_input} = CheckoutStartInput.new(%{})
    assert {:ok, started} = Checkout.start_from_cart(user, first_token, start_input)

    assert {:error, error} = Facade.add_item_for_user(user, second_token, add_input)
    assert error.code == "SUBSCRIPTION_DUPLICATE"

    order =
      Order
      |> Ash.Query.filter(expr(id == ^started.order_id))
      |> Ash.read!(domain: Store.Orders, authorize?: false, context: %{system?: true})
      |> List.first()

    assert {:ok, _updated_order} =
             order
             |> Ash.Changeset.for_update(:mark_payment_failed, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Orders,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, _cart} = Facade.add_item_for_user(user, second_token, add_input)
  end

  defp published_variant_id! do
    admin = TestFixtures.register_user!(email: TestFixtures.unique_email("cart_admin"))
    _role = TestFixtures.assign_role!(admin, :admin)

    product =
      Store.Catalog.Product
      |> Ash.Changeset.for_create(
        :create_draft,
        %{
          slug: "phase20-cart-#{System.unique_integer([:positive])}",
          title: "Phase 20 Cart Product",
          base_variant_sku: "P20-CART-#{System.unique_integer([:positive])}",
          base_variant_currency_code: "USD",
          base_variant_price_minor: 1_500,
          base_variant_stock_on_hand: 50
        }
      )
      |> Ash.create!(domain: Store.Catalog, actor: admin)

    published =
      product
      |> Ash.Changeset.for_update(:publish, %{})
      |> Ash.update!(domain: Store.Catalog, actor: admin)

    published.default_variant_id
  end

  defp enable_subscription_purchase! do
    current_flags = Application.get_env(:store, :subscription_features, [])

    Application.put_env(
      :store,
      :subscription_features,
      Keyword.merge(current_flags, expose_purchase?: true)
    )
  end
end
