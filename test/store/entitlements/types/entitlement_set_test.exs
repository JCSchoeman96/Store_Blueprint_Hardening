defmodule Store.Entitlements.Types.EntitlementSetTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Types.EntitlementSet

  @as_of ~U[2025-01-01 00:00:00.000000Z]

  test "a grant is ineffective before its inclusive start" do
    grant = grant(valid_from_at: DateTime.add(@as_of, 1, :microsecond))

    assert EntitlementSet.effective_grants(set([grant]), @as_of) == []
    refute EntitlementSet.has_entitlement?(set([grant]), :membership_access, "scope", @as_of)
  end

  test "the start is inclusive at microsecond precision" do
    grants = [
      grant(scope_key: "before", valid_from_at: DateTime.add(@as_of, -1, :microsecond)),
      grant(scope_key: "equal", valid_from_at: @as_of),
      grant(scope_key: "after", valid_from_at: DateTime.add(@as_of, 1, :microsecond))
    ]

    assert effective_scopes(grants, @as_of) == MapSet.new(["before", "equal"])
  end

  test "the end is exclusive at microsecond precision" do
    grants = [
      grant(scope_key: "before", valid_to_at: DateTime.add(@as_of, 1, :microsecond)),
      grant(scope_key: "equal", valid_to_at: @as_of),
      grant(scope_key: "after", valid_to_at: DateTime.add(@as_of, -1, :microsecond))
    ]

    assert effective_scopes(grants, @as_of) == MapSet.new(["before"])
  end

  test "a missing start fails closed and a missing end is open-ended" do
    grants = [
      grant(scope_key: "missing-start", valid_from_at: nil),
      grant(scope_key: "open-ended", valid_to_at: nil)
    ]

    assert effective_scopes(grants, @as_of) == MapSet.new(["open-ended"])
  end

  test "revoked, inactive, and expired grants are ineffective within their interval" do
    grants = [
      grant(scope_key: "revoked-status", status: :revoked),
      grant(scope_key: "revoked-at", revoked_at: @as_of),
      grant(scope_key: "inactive", status: :inactive),
      grant(scope_key: "expired", status: :expired)
    ]

    assert effective_scopes(grants, @as_of) == MapSet.new()
  end

  test "overlapping and mixed grants are filtered independently" do
    grants = [
      grant(scope_key: "overlap-one", valid_to_at: DateTime.add(@as_of, 5, :second)),
      grant(scope_key: "overlap-two", valid_from_at: @as_of, valid_to_at: nil),
      grant(
        scope_key: "future",
        valid_from_at: DateTime.add(@as_of, 1, :second),
        valid_to_at: DateTime.add(@as_of, 10, :second)
      ),
      grant(
        scope_key: "ended",
        valid_from_at: DateTime.add(@as_of, -10, :second),
        valid_to_at: DateTime.add(@as_of, -1, :microsecond)
      ),
      grant(
        scope_key: "revoked",
        revoked_at: @as_of,
        valid_to_at: DateTime.add(@as_of, 10, :second)
      ),
      grant(scope_key: "missing-start", valid_from_at: nil)
    ]

    assert effective_scopes(grants, @as_of) == MapSet.new(["overlap-one", "overlap-two"])
  end

  test "the nearest future boundary can change the effective grant list" do
    grants = [
      grant(
        scope_key: "current-end",
        valid_to_at: DateTime.add(@as_of, 5, :second)
      ),
      grant(
        scope_key: "future-start",
        valid_from_at: DateTime.add(@as_of, 10, :second),
        valid_to_at: DateTime.add(@as_of, 20, :second)
      ),
      grant(
        scope_key: "never-effective",
        valid_from_at: DateTime.add(@as_of, 2, :second),
        valid_to_at: DateTime.add(@as_of, 1, :second)
      ),
      grant(
        scope_key: "revoked-future",
        status: :revoked,
        valid_from_at: DateTime.add(@as_of, 1, :second)
      )
    ]

    assert EntitlementSet.next_temporal_boundary(set(grants), @as_of) ==
             DateTime.add(@as_of, 5, :second)
  end

  test "a future start is a boundary only when the grant can become effective" do
    grants = [
      grant(scope_key: "future-open", valid_from_at: DateTime.add(@as_of, 2, :second)),
      grant(
        scope_key: "future-bounded",
        valid_from_at: DateTime.add(@as_of, 3, :second),
        valid_to_at: DateTime.add(@as_of, 4, :second)
      ),
      grant(scope_key: "missing-start", valid_from_at: nil),
      grant(
        scope_key: "already-ended",
        valid_from_at: DateTime.add(@as_of, -2, :second),
        valid_to_at: DateTime.add(@as_of, -1, :second)
      )
    ]

    assert EntitlementSet.next_temporal_boundary(set(grants), @as_of) ==
             DateTime.add(@as_of, 2, :second)

    assert EntitlementSet.next_temporal_boundary(set([grant()]), @as_of) == nil
  end

  test "a grant at its exact start contributes its future end" do
    end_at = DateTime.add(@as_of, 2, :second)
    grant = grant(valid_from_at: @as_of, valid_to_at: end_at)

    assert EntitlementSet.next_temporal_boundary(set([grant]), @as_of) == end_at
  end

  test "DateTime offsets compare by instant and repeated evaluation is deterministic" do
    {:ok, same_instant, 3_600} = DateTime.from_iso8601("2025-01-01T01:00:00.000000+01:00")
    grant = grant(valid_from_at: same_instant)
    entitlement_set = set([grant])

    first = EntitlementSet.effective_grants(entitlement_set, @as_of)
    second = EntitlementSet.effective_grants(entitlement_set, @as_of)

    assert length(first) == 1
    assert first == second
  end

  defp effective_scopes(grants, as_of) do
    grants
    |> set()
    |> EntitlementSet.effective_grants(as_of)
    |> Enum.map(& &1.scope_key)
    |> MapSet.new()
  end

  defp set(grants) do
    %EntitlementSet{
      user_id: "user-1",
      grants: grants,
      fetched_at: @as_of,
      expires_at: DateTime.add(@as_of, 60, :second)
    }
  end

  defp grant(attrs) do
    defaults = [
      kind: :membership_access,
      scope_key: "scope",
      status: :active,
      revoked_at: nil,
      valid_from_at: @as_of,
      valid_to_at: nil
    ]

    struct!(EntitlementGrant, Keyword.merge(defaults, attrs))
  end

  defp grant, do: grant([])
end
