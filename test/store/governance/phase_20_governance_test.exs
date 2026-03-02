defmodule Store.Governance.Phase20GovernanceTest do
  use ExUnit.Case, async: true

  alias Store.Support.Governance.SurfaceRegistry
  alias Store.Support.Governance.UniquenessRegistry

  test "uniqueness registry includes phase 20 cart and checkout draft constraints" do
    active_keys = UniquenessRegistry.active_now() |> Enum.map(& &1.key) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               :carts_active_token,
               :carts_active_user_id,
               :cart_items_cart_variant,
               :checkout_drafts_checkout_key,
               :checkout_drafts_cart_id_cart_version
             ]),
             active_keys
           )
  end

  test "surface registry includes cart facade exports" do
    assert [
             {:get_cart_for_user, 2},
             {:get_cart_view_for_user, 3},
             {:add_item_for_user, 3},
             {:update_item_qty_for_user, 3},
             {:remove_item_for_user, 3},
             {:merge_token_into_user_for_user, 2}
           ] == SurfaceRegistry.allowed_exports(Store.Carts.Facade)
  end

  test "policy matrix and route inventory pin phase 20 web behavior" do
    policy_matrix = File.read!("docs/governance/policy_matrix.md")
    route_inventory = File.read!("docs/governance/route_inventory.md")

    assert policy_matrix =~ "### 5.8 Carts & Checkout Drafts"

    assert policy_matrix =~
             "| CheckoutDraft | X(start_from_cart) | YES | YES | NO | NO | SELF** |"

    assert route_inventory =~ "| GET | `/cart` | LiveView (`StoreWeb.CartLive :index`) | Yes |"

    assert route_inventory =~
             "| GET | `/checkout` | LiveView (`StoreWeb.CheckoutLive.Placeholder :index`) | Yes |"
  end
end
