defmodule Store.Entitlements.FacadeTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.{Cache, EntitlementGrant, Facade}
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "issue_subscription_entitlement_for_system upserts and refreshes validity window" do
    customer = SubscriptionsFixtures.create_customer!("phase26_entitlement_issue")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:gold"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, initial} = Facade.issue_subscription_entitlement_for_system(subscription, plan)
    assert initial.status == :active
    assert initial.valid_to_at == subscription.current_period_end_at

    assert {:ok, _revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(subscription.id, "test_revoke")

    later_period_end = DateTime.add(subscription.current_period_end_at, 2_592_000, :second)

    assert {:ok, updated_subscription} =
             subscription
             |> Ash.Changeset.for_update(
               :extend_period,
               %{
                 current_period_start_at: subscription.current_period_end_at,
                 current_period_end_at: later_period_end,
                 next_renewal_at: later_period_end
               },
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:ok, upserted} =
             Facade.issue_subscription_entitlement_for_system(updated_subscription, plan)

    assert upserted.id == initial.id
    assert upserted.status == :active
    assert upserted.revoked_at == nil
    assert upserted.revoked_reason == nil
    assert upserted.valid_to_at == later_period_end
  end

  test "revoke_subscription_entitlements_for_system revokes all grants for subscription source" do
    customer = SubscriptionsFixtures.create_customer!("phase26_entitlement_revoke")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :digital_library,
        entitlement_scope_key: "library:premium"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)

    assert {:ok, revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(subscription.id, "canceled_now")

    assert revoked_count == 1

    grant = fetch_entitlement!(subscription.id)
    assert grant.status == :revoked
    assert grant.revoked_reason == "canceled_now"
  end

  test "entitlement_set_for_user caches, invalidates, and evaluates validity at read time" do
    customer = SubscriptionsFixtures.create_customer!("phase27a_entitlement_cache")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:cached"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)

    assert {:ok, first_set} = Facade.entitlement_set_for_user(customer)
    assert {:ok, second_set} = Facade.entitlement_set_for_user(customer)

    assert first_set.fetched_at == second_set.fetched_at
    assert EntitlementSet.has_entitlement?(first_set, :membership_access, "membership:cached")

    customer_id = customer.id

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(customer_id))

    assert {:ok, _revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(subscription.id, "cache_revoke")

    assert_receive {:entitlements_invalidated, ^customer_id, "cache_revoke", _occurred_at}

    assert {:ok, refreshed_set} = Facade.entitlement_set_for_user(customer)
    refute refreshed_set.fetched_at == first_set.fetched_at
    refute EntitlementSet.has_entitlement?(refreshed_set, :membership_access, "membership:cached")

    short_lived_subscription =
      subscription
      |> Ash.Changeset.for_update(
        :extend_period,
        %{
          current_period_end_at:
            DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.truncate(:microsecond)
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert {:ok, _grant} =
             Facade.issue_subscription_entitlement_for_system(short_lived_subscription, plan)

    assert {:ok, short_lived_set} = Facade.entitlement_set_for_user(customer)

    assert EntitlementSet.has_entitlement?(
             short_lived_set,
             :membership_access,
             "membership:cached"
           )

    Process.sleep(1_100)

    refute EntitlementSet.has_entitlement?(
             short_lived_set,
             :membership_access,
             "membership:cached"
           )

    assert EntitlementSet.effective_grants(short_lived_set) == []
  end

  test "entitlement_set_for_user coalesces concurrent cache misses" do
    customer = SubscriptionsFixtures.create_customer!("phase27a_entitlement_single_flight")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:single-flight"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)

    telemetry_ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "entitlement-cache-test-#{inspect(telemetry_ref)}",
      [[:store, :repo, :query]],
      fn _event, _measurements, metadata, _config ->
        if is_binary(metadata.query) and String.contains?(metadata.query, "entitlement_grants") do
          send(parent, {:entitlement_query, telemetry_ref})
        end
      end,
      nil
    )

    try do
      tasks =
        for _ <- 1..6 do
          Task.async(fn -> Facade.entitlement_set_for_user(customer) end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, _}, &1))

      fetched_times =
        results
        |> Enum.map(fn {:ok, set} -> set.fetched_at end)
        |> Enum.uniq()

      assert length(fetched_times) == 1
      assert drain_query_messages(telemetry_ref, 0) == 1
    after
      :telemetry.detach("entitlement-cache-test-#{inspect(telemetry_ref)}")
    end
  end

  test "worker-driven membership expiration invalidates the entitlement cache post-commit" do
    customer = SubscriptionsFixtures.create_customer!("phase27a_worker_revoke")
    customer_id = customer.id
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:worker-revoke",
        max_retry_attempts: 0
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: nil,
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)
    assert {:ok, cached_set} = Facade.entitlement_set_for_user(customer)

    assert EntitlementSet.has_entitlement?(
             cached_set,
             :membership_access,
             "membership:worker-revoke"
           )

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(customer.id))

    assert {:error, _reason} =
             SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription.id,
               now: now
             )

    assert_receive {:entitlements_invalidated, ^customer_id, "grace_expired", _occurred_at}

    assert {:ok, refreshed_set} = Facade.entitlement_set_for_user(customer)
    assert EntitlementSet.effective_grants(refreshed_set) == []
  end

  defp fetch_entitlement!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
    |> List.first()
  end

  defp drain_query_messages(telemetry_ref, count) do
    receive do
      {:entitlement_query, ^telemetry_ref} -> drain_query_messages(telemetry_ref, count + 1)
    after
      100 -> count
    end
  end
end
