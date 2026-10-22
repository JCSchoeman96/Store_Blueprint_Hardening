defmodule Store.Entitlements.SourceConvergenceValidatorTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Entitlements.SourceConvergence
  alias Store.Support.Errors.Error

  @subscription_id "11111111-1111-4111-8111-111111111111"
  @other_subscription_id "99999999-9999-4999-8999-999999999999"
  @user_id "22222222-2222-4222-8222-222222222222"
  @other_user_id_upper "BBBBBBBB-0000-4000-8000-000000000002"
  @other_user_id_lower "bbbbbbbb-0000-4000-8000-000000000002"
  @target_grant_id "33333333-3333-4333-8333-333333333333"
  @other_grant_id "44444444-4444-4444-8444-444444444444"
  @start_at ~U[2026-01-01 12:00:00.123456Z]
  @end_at ~U[2026-02-01 12:00:00.654321Z]
  @target_fingerprint String.duplicate("a", 64)

  test "derives a PAIR with an active matching target" do
    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), [row()])

    assert state.mode == :pair
    assert state.matching_target_id == @target_grant_id
    assert state.active_non_target_ids == []
    assert state.expected_revoke_count == 0
    assert state.projection_user_ids == [@user_id]
  end

  test "derives a matching target even when it is revoked" do
    revoked =
      row(%{
        status: :revoked,
        revoked_at: @end_at,
        revoked_reason: "previously revoked"
      })

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), [revoked])

    assert state.mode == :pair
    assert state.matching_target_id == @target_grant_id
    assert state.active_non_target_ids == []
    assert state.expected_revoke_count == 0
  end

  test "derives a PAIR with no matching target" do
    active_non_target = row(%{id: @other_grant_id, scope_key: "membership:silver"})

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), [active_non_target])

    assert state.mode == :pair
    assert state.matching_target_id == nil
    assert state.active_non_target_ids == [@other_grant_id]
    assert state.expected_revoke_count == 1
  end

  test "derives every active non-target row and counts them" do
    matching_target = row()
    first_non_target = row(%{id: @other_grant_id, scope_key: "membership:silver"})
    second_non_target = row(%{id: "55555555-5555-4555-8555-555555555555", kind: :digital_library})

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), [
               second_non_target,
               matching_target,
               first_non_target
             ])

    assert state.matching_target_id == @target_grant_id

    assert state.active_non_target_ids == [
             @other_grant_id,
             "55555555-5555-4555-8555-555555555555"
           ]

    assert state.expected_revoke_count == 2
  end

  test "does not treat revoked or expired rows as revoke candidates" do
    revoked =
      row(%{
        id: @other_grant_id,
        scope_key: "membership:silver",
        status: :revoked,
        revoked_at: @end_at,
        revoked_reason: "old"
      })

    expired =
      row(%{
        id: "55555555-5555-4555-8555-555555555555",
        scope_key: "membership:bronze",
        status: :expired
      })

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), [revoked, expired])

    assert state.active_non_target_ids == []
    assert state.expected_revoke_count == 0
  end

  test "derives EFFECTIVE and NON_EFFECTIVE empty targets with zero rows" do
    for disposition <- [:effective, :non_effective] do
      assert {:ok, state} =
               SourceConvergence.derive_locked_source_state(empty_input(disposition), [])

      assert state.mode == :empty
      assert state.matching_target_id == nil
      assert state.active_non_target_ids == []
      assert state.expected_revoke_count == 0
      assert state.projection_user_ids == [@user_id]
    end
  end

  test "EMPTY revokes every active same-source row for either disposition" do
    rows = [
      row(%{id: @target_grant_id}),
      row(%{id: @other_grant_id, status: :revoked, revoked_at: @end_at}),
      row(%{id: "55555555-5555-4555-8555-555555555555", status: :expired})
    ]

    for disposition <- [:effective, :non_effective] do
      assert {:ok, state} =
               SourceConvergence.derive_locked_source_state(empty_input(disposition), rows)

      assert state.mode == :empty
      assert state.matching_target_id == nil
      assert state.active_non_target_ids == [@target_grant_id]
      assert state.expected_revoke_count == 1
    end
  end

  test "deduplicates projection users by UUID bytes and retains the owner" do
    rows = [
      row(%{
        id: @other_grant_id,
        scope_key: "membership:silver",
        user_id: @other_user_id_upper
      }),
      row(%{
        id: "55555555-5555-4555-8555-555555555555",
        scope_key: "membership:bronze",
        user_id: @other_user_id_lower
      })
    ]

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), rows)

    assert state.projection_user_ids == [@user_id, @other_user_id_lower]
  end

  test "sorts revoke and projection UUIDs by decoded binary order" do
    lower_a_id = "aaaaaaaa-0000-4000-8000-000000000001"
    upper_b_id = "BBBBBBBB-0000-4000-8000-000000000002"

    rows = [
      row(%{
        id: upper_b_id,
        scope_key: "membership:silver",
        user_id: upper_b_id
      }),
      row(%{
        id: lower_a_id,
        scope_key: "membership:bronze",
        user_id: lower_a_id
      })
    ]

    assert {:ok, state} =
             SourceConvergence.derive_locked_source_state(input(), rows)

    assert state.active_non_target_ids == [
             lower_a_id,
             String.downcase(upper_b_id)
           ]

    assert state.projection_user_ids == [
             @user_id,
             lower_a_id,
             String.downcase(upper_b_id)
           ]
  end

  test "fails closed when a locked row has the wrong source kind or source ID" do
    assert_internal_error(
      SourceConvergence.derive_locked_source_state(input(), [row(%{source_kind: :other})])
    )

    assert_internal_error(
      SourceConvergence.derive_locked_source_state(
        input(),
        [row(%{source_id: @other_subscription_id})]
      )
    )
  end

  test "fails closed for malformed locked rows and non-list input" do
    assert_internal_error(
      SourceConvergence.derive_locked_source_state(input(), [Map.delete(row(), :status)])
    )

    assert_internal_error(
      SourceConvergence.derive_locked_source_state(input(), [row(%{id: "invalid"})])
    )

    assert_internal_error(SourceConvergence.derive_locked_source_state(input(), :not_a_list))
  end

  test "fails closed for an impossible typed target shape" do
    half_pair = %{input() | entitlement_kind: nil}
    missing_start = %{input() | valid_from_at: nil}
    non_effective_pair = %{input() | disposition: :non_effective}

    for impossible_input <- [half_pair, missing_start, non_effective_pair] do
      assert_internal_error(SourceConvergence.derive_locked_source_state(impossible_input, []))
    end

    empty_with_start = %{empty_input(:effective) | valid_from_at: @start_at}

    assert_internal_error(SourceConvergence.derive_locked_source_state(empty_with_start, []))
  end

  test "validates a complete PAIR with a finite end" do
    assert :ok =
             SourceConvergence.validate_final_active_set(input(), @target_grant_id, [row()])
  end

  test "validates a complete PAIR with a nil end" do
    pair_input = input(%{valid_until_at: nil})
    pair_row = row(%{valid_to_at: nil})

    assert :ok =
             SourceConvergence.validate_final_active_set(pair_input, @target_grant_id, [pair_row])
  end

  test "validates EMPTY with no target and no selected rows for either disposition" do
    for disposition <- [:effective, :non_effective] do
      assert :ok =
               SourceConvergence.validate_final_active_set(
                 empty_input(disposition),
                 nil,
                 []
               )
    end
  end

  test "rejects a PAIR with no target ID, no rows, or multiple rows" do
    assert_internal_error(SourceConvergence.validate_final_active_set(input(), nil, [row()]))

    assert_internal_error(
      SourceConvergence.validate_final_active_set(input(), @target_grant_id, [])
    )

    assert_internal_error(
      SourceConvergence.validate_final_active_set(input(), @target_grant_id, [
        row(),
        row(%{id: @other_grant_id})
      ])
    )
  end

  test "rejects a PAIR with a wrong target ID or invalid target ID" do
    assert_internal_error(
      SourceConvergence.validate_final_active_set(input(), @other_grant_id, [row()])
    )

    assert_internal_error(
      SourceConvergence.validate_final_active_set(input(), "invalid", [row()])
    )
  end

  test "rejects each mismatched final PAIR field independently" do
    mismatches = [
      %{id: @other_grant_id},
      %{user_id: @other_user_id_lower},
      %{kind: :digital_library},
      %{scope_key: "membership:silver"},
      %{source_kind: :other},
      %{source_id: @other_subscription_id},
      %{status: :revoked},
      %{valid_from_at: DateTime.add(@start_at, 1, :microsecond)},
      %{valid_to_at: DateTime.add(@end_at, 1, :microsecond)},
      %{revoked_at: @end_at},
      %{revoked_reason: "manual revocation"}
    ]

    for mismatch <- mismatches do
      assert_internal_error(
        SourceConvergence.validate_final_active_set(
          input(),
          @target_grant_id,
          [row(mismatch)]
        )
      )
    end

    assert_internal_error(
      SourceConvergence.validate_final_active_set(
        input(%{valid_until_at: nil}),
        @target_grant_id,
        [row(%{valid_to_at: @end_at})]
      )
    )
  end

  test "rejects malformed selected rows and invalid selected-row input" do
    assert_internal_error(
      SourceConvergence.validate_final_active_set(
        input(),
        @target_grant_id,
        [Map.delete(row(), :valid_from_at)]
      )
    )

    assert_internal_error(
      SourceConvergence.validate_final_active_set(input(), @target_grant_id, :not_a_list)
    )
  end

  test "EMPTY rejects a target ID even when no rows are selected" do
    assert_internal_error(
      SourceConvergence.validate_final_active_set(
        empty_input(:effective),
        @target_grant_id,
        []
      )
    )
  end

  test "EMPTY rejects any selected active row" do
    assert_internal_error(
      SourceConvergence.validate_final_active_set(
        empty_input(:non_effective),
        nil,
        [row()]
      )
    )
  end

  test "validator fails closed for an impossible typed target shape" do
    assert_internal_error(
      SourceConvergence.validate_final_active_set(
        %{input() | entitlement_scope_key: nil},
        @target_grant_id,
        [row()]
      )
    )
  end

  defp input(overrides \\ %{}) do
    params =
      %{
        subscription_id: @subscription_id,
        user_id: @user_id,
        disposition: :effective,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold",
        valid_from_at: @start_at,
        valid_until_at: @end_at,
        reason: "subscription source changed",
        access_effect_id: "66666666-6666-4666-8666-666666666666",
        source_version: 1,
        target_fingerprint: @target_fingerprint
      }
      |> Map.merge(overrides)

    {:ok, input} = SubscriptionSourceConvergenceInput.new(params)
    input
  end

  defp empty_input(disposition, valid_until_at \\ nil) do
    input(%{
      disposition: disposition,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: valid_until_at
    })
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        id: @target_grant_id,
        user_id: @user_id,
        kind: :membership_access,
        scope_key: "membership:gold",
        source_kind: :subscription,
        source_id: @subscription_id,
        status: :active,
        valid_from_at: @start_at,
        valid_to_at: @end_at,
        revoked_at: nil,
        revoked_reason: nil
      },
      overrides
    )
  end

  defp assert_internal_error(result) do
    assert {:error, %Error{code: "INTERNAL_ERROR"}} = result
  end
end
