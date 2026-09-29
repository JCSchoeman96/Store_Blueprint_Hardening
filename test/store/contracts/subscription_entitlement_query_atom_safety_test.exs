defmodule Store.Contracts.SubscriptionEntitlementQueryAtomSafetyTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.Queries.UserEntitlementIndexQuery

  alias Store.Subscriptions.Queries.{
    AdminSubscriptionIndexQuery,
    UserSubscriptionIndexQuery
  }

  test "user subscription query does not intern an invalid runtime status" do
    refute_status_interned!(
      UserSubscriptionIndexQuery,
      "s0_mem_atom_02_user_subscription_invalid_status"
    )
  end

  test "admin subscription query does not intern an invalid runtime status" do
    refute_status_interned!(
      AdminSubscriptionIndexQuery,
      "s0_mem_atom_02_admin_subscription_invalid_status"
    )
  end

  test "user entitlement query does not intern an invalid runtime status" do
    refute_status_interned!(
      UserEntitlementIndexQuery,
      "s0_mem_atom_02_user_entitlement_invalid_status"
    )
  end

  describe "UserSubscriptionIndexQuery status parsing" do
    test "keeps nil and empty statuses absent" do
      assert_status(UserSubscriptionIndexQuery, nil, nil)
      assert_status(UserSubscriptionIndexQuery, "", nil)
    end

    test "accepts atoms and normalized binary statuses" do
      assert_status(UserSubscriptionIndexQuery, :active, :active)
      assert_status(UserSubscriptionIndexQuery, "active", :active)
      assert_status(UserSubscriptionIndexQuery, " Past_Due ", :past_due)
    end

    test "rejects invalid binary and existing atom statuses" do
      assert_invalid_status(UserSubscriptionIndexQuery, "not-a-status")
      assert_invalid_status(UserSubscriptionIndexQuery, :not_a_status)
    end

    test "rejects arbitrary status value types" do
      assert_invalid_status(UserSubscriptionIndexQuery, 123)
      assert_invalid_status(UserSubscriptionIndexQuery, ["active"])
      assert_invalid_status(UserSubscriptionIndexQuery, %{"status" => "active"})
    end
  end

  describe "AdminSubscriptionIndexQuery status parsing" do
    test "keeps nil and empty statuses absent" do
      assert_status(AdminSubscriptionIndexQuery, nil, nil)
      assert_status(AdminSubscriptionIndexQuery, "", nil)
    end

    test "accepts atoms and normalized binary statuses" do
      assert_status(AdminSubscriptionIndexQuery, :active, :active)
      assert_status(AdminSubscriptionIndexQuery, "active", :active)
      assert_status(AdminSubscriptionIndexQuery, " Past_Due ", :past_due)
    end

    test "rejects invalid binary and existing atom statuses" do
      assert_invalid_status(AdminSubscriptionIndexQuery, "not-a-status")
      assert_invalid_status(AdminSubscriptionIndexQuery, :not_a_status)
    end

    test "rejects arbitrary status value types" do
      assert_invalid_status(AdminSubscriptionIndexQuery, 123)
      assert_invalid_status(AdminSubscriptionIndexQuery, ["active"])
      assert_invalid_status(AdminSubscriptionIndexQuery, %{"status" => "active"})
    end
  end

  describe "UserEntitlementIndexQuery status parsing" do
    test "keeps nil and empty statuses absent" do
      assert_status(UserEntitlementIndexQuery, nil, nil)
      assert_status(UserEntitlementIndexQuery, "", nil)
    end

    test "accepts atoms and normalized binary statuses" do
      assert_status(UserEntitlementIndexQuery, :active, :active)
      assert_status(UserEntitlementIndexQuery, "active", :active)
      assert_status(UserEntitlementIndexQuery, " Revoked ", :revoked)
    end

    test "rejects invalid binary and existing atom statuses" do
      assert_invalid_status(UserEntitlementIndexQuery, "not-a-status")
      assert_invalid_status(UserEntitlementIndexQuery, :not_a_status)
    end

    test "rejects arbitrary status value types" do
      assert_invalid_status(UserEntitlementIndexQuery, 123)
      assert_invalid_status(UserEntitlementIndexQuery, ["active"])
      assert_invalid_status(UserEntitlementIndexQuery, %{"status" => "active"})
    end
  end

  defp refute_status_interned!(query_module, prefix) do
    unique_invalid_status = "#{prefix}_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_invalid_status) end

    assert {:error, error} = query_module.new(%{"status" => unique_invalid_status})
    assert error.code == "VALIDATION_ERROR"
    assert error.message == "status is invalid"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_invalid_status) end
  end

  defp assert_status(query_module, input, expected_status) do
    assert {:ok, query} = query_module.new(%{"status" => input})
    assert query.status == expected_status
  end

  defp assert_invalid_status(query_module, input) do
    assert {:error, error} = query_module.new(%{"status" => input})
    assert error.code == "VALIDATION_ERROR"
    assert error.message == "status is invalid"
  end
end
