defmodule Store.Entitlements.EntitlementGrantConvergenceActionsTest do
  use Store.DataCase, async: false

  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.SubscriptionsFixtures

  @system_context %{system?: true}

  test "convergence target creates an active subscription grant with the exact interval" do
    source = create_source_fixture!("task3_target_create")
    valid_from_at = utc_now()
    valid_to_at = DateTime.add(valid_from_at, 86_400, :second)

    action = Ash.Resource.Info.action(EntitlementGrant, :converge_source_target)

    assert %Ash.Resource.Actions.Create{} = action

    assert action.accept == [
             :user_id,
             :kind,
             :scope_key,
             :source_id,
             :valid_from_at,
             :valid_to_at
           ]

    assert action.upsert? == true
    assert action.upsert_identity == :unique_user_scope_source

    assert action.upsert_fields == [
             :status,
             :valid_from_at,
             :valid_to_at,
             :revoked_at,
             :revoked_reason,
             :updated_at
           ]

    refute :status in action.accept
    refute :revoked_at in action.accept
    refute :revoked_reason in action.accept

    assert {:ok, grant} =
             create_target!(source, valid_from_at, valid_to_at)

    assert grant.source_kind == :subscription
    assert grant.source_id == source.subscription_id
    assert grant.user_id == source.user_id
    assert grant.kind == :membership_access
    assert grant.scope_key == source.scope_key
    assert grant.status == :active
    assert grant.valid_from_at == valid_from_at
    assert grant.valid_to_at == valid_to_at
    assert grant.revoked_at == nil
    assert grant.revoked_reason == nil
  end

  test "convergence target reactivates the same identity and clears revocation fields in one upsert" do
    source = create_source_fixture!("task3_target_reactivate")
    old_start = utc_now()
    old_end = DateTime.add(old_start, 3_600, :second)
    revoked_at = DateTime.add(old_start, 1, :second)

    existing =
      legacy_issue!(source, %{
        status: :revoked,
        valid_from_at: old_start,
        valid_to_at: old_end,
        revoked_at: revoked_at,
        revoked_reason: "previous revocation"
      })

    new_start = DateTime.add(old_start, 7_200, :second)
    new_end = DateTime.add(new_start, 7_200, :second)

    {{:ok, reactivated}, writes} =
      capture_entitlement_writes(fn -> create_target!(source, new_start, new_end) end)

    assert reactivated.id == existing.id
    assert reactivated.status == :active
    assert reactivated.valid_from_at == new_start
    assert reactivated.valid_to_at == new_end
    assert reactivated.revoked_at == nil
    assert reactivated.revoked_reason == nil
    assert_single_upsert(writes)
  end

  test "convergence target clears a persisted finite end when the new end is nil" do
    source = create_source_fixture!("task3_target_nil_end")
    old_start = utc_now()
    old_end = DateTime.add(old_start, 3_600, :second)

    existing =
      legacy_issue!(source, %{
        status: :revoked,
        valid_from_at: old_start,
        valid_to_at: old_end,
        revoked_at: DateTime.add(old_start, 1, :second),
        revoked_reason: "previous revocation"
      })

    new_start = DateTime.add(old_start, 7_200, :second)

    {{:ok, reactivated}, writes} =
      capture_entitlement_writes(fn -> create_target!(source, new_start, nil) end)

    assert reactivated.id == existing.id
    assert reactivated.status == :active
    assert reactivated.valid_from_at == new_start
    assert reactivated.valid_to_at == nil
    assert reactivated.revoked_at == nil
    assert reactivated.revoked_reason == nil
    assert_single_upsert(writes)
  end

  test "generic issue keeps its accepted fields and upsert contract" do
    action = Ash.Resource.Info.action(EntitlementGrant, :issue)

    assert %Ash.Resource.Actions.Create{} = action

    assert action.accept == [
             :user_id,
             :kind,
             :scope_key,
             :source_kind,
             :source_id,
             :status,
             :valid_from_at,
             :valid_to_at,
             :revoked_at,
             :revoked_reason
           ]

    assert action.upsert? == true
    assert action.upsert_identity == :unique_user_scope_source

    assert action.upsert_fields == [
             :status,
             :valid_to_at,
             :revoked_at,
             :revoked_reason,
             :updated_at
           ]

    assert action.return_skipped_upsert? == true
    refute :valid_from_at in action.upsert_fields

    source = create_source_fixture!("task3_issue_unchanged")
    original_start = utc_now()
    original_end = DateTime.add(original_start, 3_600, :second)

    original =
      legacy_issue!(source, %{
        status: :active,
        valid_from_at: original_start,
        valid_to_at: original_end
      })

    changed_start = DateTime.add(original_start, 7_200, :second)
    changed_end = DateTime.add(changed_start, 3_600, :second)

    updated =
      legacy_issue!(source, %{
        status: :expired,
        valid_from_at: changed_start,
        valid_to_at: changed_end
      })

    assert updated.id == original.id
    assert updated.status == :expired
    assert updated.valid_from_at == original_start
    assert updated.valid_to_at == changed_end
  end

  test "generic revoke remains non-atomic and accepts only revocation fields" do
    action = Ash.Resource.Info.action(EntitlementGrant, :revoke)

    assert %Ash.Resource.Actions.Update{} = action
    assert action.require_atomic? == false
    assert action.accept == [:revoked_reason, :revoked_at]

    source = create_source_fixture!("task3_revoke_legacy")
    grant = legacy_issue!(source, %{status: :active, valid_from_at: utc_now()})

    assert {:ok, revoked} =
             grant
             |> Ash.Changeset.for_update(:revoke, %{revoked_reason: "legacy revoke"},
               context: @system_context
             )
             |> Ash.update(
               domain: Store.Entitlements,
               authorize?: false,
               context: @system_context
             )

    assert revoked.status == :revoked
    assert revoked.revoked_reason == "legacy revoke"
    assert %DateTime{} = revoked.revoked_at
  end

  test "valid_from_at remains required and defaults to DateTime.utc_now/0" do
    attribute = Ash.Resource.Info.attribute(EntitlementGrant, :valid_from_at)

    assert attribute.allow_nil? == false
    assert attribute.default == (&DateTime.utc_now/0)
  end

  test "source convergence revoke passes the atomic precheck and persists its reason" do
    source = create_source_fixture!("task3_revoke_atomic")
    grant = legacy_issue!(source, %{status: :active, valid_from_at: utc_now()})
    reason = "source convergence revoke"

    action = Ash.Resource.Info.action(EntitlementGrant, :revoke_for_source_convergence)

    assert %Ash.Resource.Actions.Update{} = action
    assert action.require_atomic? == true
    assert action.accept == [:revoked_reason]
    assert action.require_attributes == [:revoked_reason]

    assert {:ok, _locked} =
             Repo.query(
               "SELECT id FROM entitlement_grants WHERE id = $1 FOR UPDATE",
               [Ecto.UUID.dump!(grant.id)]
             )

    atomic_changeset =
      Ash.Changeset.fully_atomic_changeset(
        EntitlementGrant,
        :revoke_for_source_convergence,
        %{revoked_reason: reason},
        data: grant,
        domain: Store.Entitlements,
        context: @system_context
      )

    assert %Ash.Changeset{} = atomic_changeset

    assert {:ok, revoked} =
             grant
             |> Ash.Changeset.for_update(
               :revoke_for_source_convergence,
               %{
                 revoked_reason: reason
               },
               context: @system_context
             )
             |> Ash.update(
               domain: Store.Entitlements,
               authorize?: false,
               context: @system_context
             )

    assert revoked.status == :revoked
    assert revoked.revoked_reason == reason
    assert %DateTime{} = revoked.revoked_at
  end

  defp create_target!(source, valid_from_at, valid_to_at) do
    attrs = %{
      user_id: source.user_id,
      kind: :membership_access,
      scope_key: source.scope_key,
      source_id: source.subscription_id,
      valid_from_at: valid_from_at,
      valid_to_at: valid_to_at
    }

    EntitlementGrant
    |> Ash.Changeset.for_create(:converge_source_target, attrs, context: @system_context)
    |> Ash.create(
      domain: Store.Entitlements,
      authorize?: false,
      context: @system_context
    )
  end

  defp legacy_issue!(source, overrides) do
    attrs =
      %{
        user_id: source.user_id,
        kind: :membership_access,
        scope_key: source.scope_key,
        source_kind: :subscription,
        source_id: source.subscription_id,
        status: :active,
        valid_from_at: utc_now(),
        valid_to_at: nil,
        revoked_at: nil,
        revoked_reason: nil
      }
      |> Map.merge(overrides)

    EntitlementGrant
    |> Ash.Changeset.for_create(:issue, attrs, context: @system_context)
    |> Ash.create!(
      domain: Store.Entitlements,
      authorize?: false,
      context: @system_context
    )
  end

  defp create_source_fixture!(prefix) do
    unique = "#{prefix}_#{Ecto.UUID.generate()}"
    customer = SubscriptionsFixtures.create_customer!(unique)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    scope_key = "task3:#{unique}"

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: scope_key
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    %{subscription_id: subscription.id, user_id: customer.id, scope_key: scope_key}
  end

  defp capture_entitlement_writes(fun) do
    ref = make_ref()
    parent = self()
    handler_id = "task3-entitlement-write-#{inspect(ref)}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query]

          if is_binary(query) and
               String.contains?(query, "entitlement_grants") and
               Regex.match?(~r/^\s*(INSERT|UPDATE|DELETE)\b/i, query) do
            send(parent, {:entitlement_write, ref, query})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_entitlement_writes(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_entitlement_writes(ref, writes) do
    receive do
      {:entitlement_write, ^ref, query} -> collect_entitlement_writes(ref, [query | writes])
    after
      25 -> Enum.reverse(writes)
    end
  end

  defp assert_single_upsert([query]) do
    assert Regex.match?(~r/^\s*INSERT\b/i, query)
    assert Regex.match?(~r/ON CONFLICT/i, query)
  end

  defp assert_single_upsert(writes) do
    flunk("expected one entitlement INSERT ... ON CONFLICT, got: #{inspect(writes)}")
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
