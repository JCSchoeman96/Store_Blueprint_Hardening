defmodule Store.Subscriptions.AccessEffectFingerprintStatusTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.AccessEffect

  @start_at ~U[2026-09-01 00:00:00.123456Z]
  @end_at ~U[2026-10-01 00:00:00.654321Z]

  test "classifies canonical V2 fingerprint evidence with a persisted start" do
    evidence = evidence()
    fingerprint = AccessEffect.target_fingerprint(evidence)
    effect = effect_with_fingerprint(evidence, fingerprint)

    assert AccessEffect.persisted_fingerprint_status(effect) == :v2_match
  end

  test "checks V2 first when persisted valid_from_at is nil" do
    evidence = evidence(%{valid_from_at: nil})
    v2_fingerprint = AccessEffect.target_fingerprint(evidence)
    v1_fingerprint = AccessEffect.legacy_target_fingerprint_v1(evidence)
    effect = effect_with_fingerprint(evidence, v2_fingerprint)

    refute v2_fingerprint == v1_fingerprint
    assert effect.valid_from_at == nil
    assert AccessEffect.persisted_fingerprint_status(effect) == :v2_match
  end

  test "classifies matching legacy V1 evidence only when the start is nil" do
    evidence = evidence(%{valid_from_at: nil})
    v1_fingerprint = AccessEffect.legacy_target_fingerprint_v1(evidence)
    effect = effect_with_fingerprint(evidence, v1_fingerprint)

    refute AccessEffect.target_fingerprint(evidence) == v1_fingerprint
    assert AccessEffect.persisted_fingerprint_status(effect) == :v1_legacy_match
    assert effect.target_fingerprint == v1_fingerprint
  end

  test "classifies a well-formed fingerprint matching neither encoding as a mismatch" do
    evidence = evidence()
    v2_fingerprint = AccessEffect.target_fingerprint(evidence)
    v1_fingerprint = AccessEffect.legacy_target_fingerprint_v1(evidence)

    mismatch_fingerprint =
      Enum.find(
        [String.duplicate("0", 64), String.duplicate("1", 64), String.duplicate("f", 64)],
        fn fingerprint -> fingerprint != v2_fingerprint and fingerprint != v1_fingerprint end
      )

    effect = effect_with_fingerprint(evidence, mismatch_fingerprint)

    assert byte_size(effect.target_fingerprint) == 64
    assert effect.target_fingerprint == String.downcase(effect.target_fingerprint)
    assert AccessEffect.persisted_fingerprint_status(effect) == :mismatch
  end

  test "does not accept a V1 hash when a persisted start is nonnil" do
    evidence = evidence()
    v1_fingerprint = AccessEffect.legacy_target_fingerprint_v1(evidence)
    effect = effect_with_fingerprint(evidence, v1_fingerprint)

    assert effect.valid_from_at == @start_at
    refute AccessEffect.target_fingerprint(evidence) == v1_fingerprint
    assert AccessEffect.persisted_fingerprint_status(effect) == :mismatch
  end

  test "fails closed when immutable UUID evidence is corrupt" do
    valid_evidence = evidence()
    v2_fingerprint = AccessEffect.target_fingerprint(valid_evidence)
    corrupt_evidence = Map.put(valid_evidence, :subscription_id, "not-a-uuid")
    effect = effect_with_fingerprint(corrupt_evidence, v2_fingerprint)

    assert AccessEffect.persisted_fingerprint_status(effect) == :mismatch
  end

  test "legacy EFFECTIVE nil-start evidence remains an integrity match" do
    evidence = evidence(%{valid_from_at: nil})
    legacy_fingerprint = AccessEffect.legacy_target_fingerprint_v1(evidence)
    effect = effect_with_fingerprint(evidence, legacy_fingerprint)

    assert effect.disposition == :effective
    assert effect.entitlement_kind == :membership_access
    assert effect.entitlement_scope_key == "members"
    assert is_nil(effect.valid_from_at)
    assert AccessEffect.persisted_fingerprint_status(effect) == :v1_legacy_match
  end

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        subscription_id: Ecto.UUID.generate(),
        source_version: 12,
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "members",
        valid_from_at: @start_at,
        valid_until_at: @end_at,
        source_order_line_item_id: Ecto.UUID.generate(),
        contract_change_id: nil,
        plan_revision_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp effect_with_fingerprint(evidence, fingerprint) do
    struct!(AccessEffect, Map.put(evidence, :target_fingerprint, fingerprint))
  end
end
