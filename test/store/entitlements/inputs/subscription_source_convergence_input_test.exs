defmodule Store.Entitlements.Inputs.SubscriptionSourceConvergenceInputTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Support.Errors.Error

  @subscription_id "11111111-1111-4111-8111-111111111111"
  @user_id "22222222-2222-4222-8222-222222222222"
  @access_effect_id "33333333-3333-4333-8333-333333333333"
  @valid_from_at ~U[2026-01-01 12:00:00.123456Z]
  @valid_until_at ~U[2026-02-01 12:00:00.654321Z]
  @target_fingerprint String.duplicate("a", 64)

  test "accepts an EFFECTIVE pair with a finite end" do
    assert {:ok, input} = SubscriptionSourceConvergenceInput.new(valid_params())

    assert input.subscription_id == @subscription_id
    assert input.user_id == @user_id
    assert input.disposition == :effective
    assert input.entitlement_kind == :membership_access
    assert input.entitlement_scope_key == "membership:gold"
    assert input.valid_from_at == @valid_from_at
    assert input.valid_until_at == @valid_until_at
    assert input.reason == "subscription access changed"
    assert input.access_effect_id == @access_effect_id
    assert input.source_version == 7
    assert input.target_fingerprint == @target_fingerprint
  end

  test "accepts an EFFECTIVE pair with no end" do
    assert {:ok, input} =
             SubscriptionSourceConvergenceInput.new(valid_params(%{valid_until_at: nil}))

    assert input.entitlement_kind == :membership_access
    assert input.entitlement_scope_key == "membership:gold"
    assert input.valid_from_at == @valid_from_at
    assert input.valid_until_at == nil
  end

  test "accepts an EFFECTIVE empty target with no end and keeps its user" do
    assert {:ok, input} = SubscriptionSourceConvergenceInput.new(empty_params(:effective))

    assert input.entitlement_kind == nil
    assert input.entitlement_scope_key == nil
    assert input.valid_from_at == nil
    assert input.user_id == @user_id
    assert input.valid_until_at == nil
  end

  test "accepts an EFFECTIVE empty target with its persisted end" do
    assert {:ok, input} =
             SubscriptionSourceConvergenceInput.new(empty_params(:effective, @valid_until_at))

    assert input.entitlement_kind == nil
    assert input.entitlement_scope_key == nil
    assert input.valid_from_at == nil
    assert input.user_id == @user_id
    assert input.valid_until_at == @valid_until_at
  end

  test "accepts a NON_EFFECTIVE empty target with no end and keeps its user" do
    assert {:ok, input} = SubscriptionSourceConvergenceInput.new(empty_params(:non_effective))

    assert input.disposition == :non_effective
    assert input.entitlement_kind == nil
    assert input.entitlement_scope_key == nil
    assert input.valid_from_at == nil
    assert input.user_id == @user_id
    assert input.valid_until_at == nil
  end

  test "accepts a NON_EFFECTIVE empty target with its persisted end" do
    assert {:ok, input} =
             SubscriptionSourceConvergenceInput.new(empty_params(:non_effective, @valid_until_at))

    assert input.disposition == :non_effective
    assert input.entitlement_kind == nil
    assert input.entitlement_scope_key == nil
    assert input.valid_from_at == nil
    assert input.user_id == @user_id
    assert input.valid_until_at == @valid_until_at
  end

  test "accepts string keys and string enum values" do
    params =
      valid_params()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("disposition", "effective")
      |> Map.put("entitlement_kind", "membership_access")

    assert {:ok, input} = SubscriptionSourceConvergenceInput.new(params)
    assert input.disposition == :effective
    assert input.entitlement_kind == :membership_access
  end

  test "preserves microsecond timestamp precision" do
    assert {:ok, input} = SubscriptionSourceConvergenceInput.new(valid_params())

    assert input.valid_from_at == @valid_from_at
    assert input.valid_until_at == @valid_until_at
    assert input.valid_from_at.microsecond == {123_456, 6}
    assert input.valid_until_at.microsecond == {654_321, 6}
  end

  test "requires valid subscription and user UUIDs" do
    for field <- [:subscription_id, :user_id] do
      assert_invalid(Map.delete(valid_params(), field))
      assert_invalid(Map.put(valid_params(), field, nil))
      assert_invalid(Map.put(valid_params(), field, "not-a-uuid"))
    end
  end

  test "requires a supported disposition and access effect UUID" do
    assert_invalid(Map.delete(valid_params(), :disposition))
    assert_invalid(Map.put(valid_params(), :disposition, nil))
    assert_invalid(Map.put(valid_params(), :disposition, "future"))
    assert_invalid(Map.delete(valid_params(), :access_effect_id))
    assert_invalid(Map.put(valid_params(), :access_effect_id, nil))
    assert_invalid(Map.put(valid_params(), :access_effect_id, "not-a-uuid"))
  end

  test "requires a positive source version" do
    assert_invalid(Map.delete(valid_params(), :source_version))

    for value <- [nil, 0, -1, "0", "invalid"] do
      assert_invalid(Map.put(valid_params(), :source_version, value))
    end
  end

  test "requires non-blank caller reason metadata" do
    assert_invalid(Map.delete(valid_params(), :reason))

    for value <- [nil, "", "   ", 12] do
      assert_invalid(Map.put(valid_params(), :reason, value))
    end
  end

  test "requires a persisted 64-character hexadecimal target fingerprint" do
    assert_invalid(Map.delete(valid_params(), :target_fingerprint))

    for value <- [nil, "", String.duplicate("a", 63), String.duplicate("g", 64), 12] do
      assert_invalid(Map.put(valid_params(), :target_fingerprint, value))
    end
  end

  test "requires explicit fields for nil-capable target evidence" do
    params = empty_params(:effective)

    for field <- [:entitlement_kind, :entitlement_scope_key, :valid_from_at, :valid_until_at] do
      assert_invalid(Map.delete(params, field))
    end
  end

  test "accepts only approved entitlement kinds" do
    for value <- [:unsupported, "unsupported"] do
      assert_invalid(Map.put(valid_params(), :entitlement_kind, value))
    end
  end

  test "rejects incomplete entitlement kind and scope pairs" do
    assert_invalid(Map.put(valid_params(), :entitlement_scope_key, nil))

    assert_invalid(
      valid_params()
      |> Map.put(:entitlement_kind, nil)
      |> Map.put(:entitlement_scope_key, "membership:gold")
    )
  end

  test "rejects blank, invalid, and oversized scopes" do
    for scope <- ["", "   ", String.duplicate("s", 256), 12, <<255>>] do
      assert_invalid(Map.put(valid_params(), :entitlement_scope_key, scope))
    end
  end

  test "rejects a NON_EFFECTIVE target with an entitlement pair" do
    assert_invalid(Map.put(valid_params(), :disposition, :non_effective))
  end

  test "rejects an EFFECTIVE pair without a start" do
    assert_invalid(Map.put(valid_params(), :valid_from_at, nil))
  end

  test "rejects an empty target with a populated start" do
    for disposition <- [:effective, :non_effective] do
      assert_invalid(Map.put(empty_params(disposition), :valid_from_at, @valid_from_at))
    end
  end

  test "rejects an end equal to or earlier than the start" do
    for end_at <- [@valid_from_at, DateTime.add(@valid_from_at, -1, :microsecond)] do
      assert_invalid(Map.put(valid_params(), :valid_until_at, end_at))
    end
  end

  test "rejects values that are not DateTime timestamps" do
    assert_invalid(Map.put(valid_params(), :valid_from_at, "2026-01-01T12:00:00Z"))
    assert_invalid(Map.put(valid_params(), :valid_until_at, ~D[2026-02-01]))
  end

  test "rejects non-map input" do
    assert_invalid(nil)
    assert_invalid([])
  end

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        subscription_id: @subscription_id,
        user_id: @user_id,
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold",
        valid_from_at: @valid_from_at,
        valid_until_at: @valid_until_at,
        reason: "subscription access changed",
        access_effect_id: @access_effect_id,
        source_version: 7,
        target_fingerprint: @target_fingerprint
      },
      overrides
    )
  end

  defp empty_params(disposition, valid_until_at \\ nil) do
    valid_params(%{
      disposition: disposition,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: valid_until_at
    })
  end

  defp assert_invalid(params) do
    assert {:error, %Error{code: "VALIDATION_ERROR"}} =
             SubscriptionSourceConvergenceInput.new(params)
  end
end
