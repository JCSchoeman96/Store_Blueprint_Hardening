defmodule Store.Subscriptions.AccessEffectExecutionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "duplicate workers serialize on source authority and converge one exact grant" do
    fixture = create_committed_suspended_effect_fixture!("jc239_effect_race")
    parent = self()

    workers =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:executor_ready, self()})

            receive do
              :execute -> Facade.execute_suspension_access_effect_for_system(fixture.effect_id)
            after
              10_000 -> {:error, :barrier_timeout}
            end
          end)
        end)
      end

    worker_pids =
      for _ <- 1..2 do
        assert_receive {:executor_ready, pid}, 10_000
        pid
      end

    Enum.each(worker_pids, &send(&1, :execute))
    results = Enum.map(workers, &Task.await(&1, 20_000))

    assert Enum.count(results, &(&1 == {:ok, :applied})) == 1
    assert Enum.count(results, &(&1 == {:ok, :noop})) == 1

    effect = fetch_effect!(fixture.effect_id)
    assert effect.status == :applied
    assert %DateTime{} = effect.projection_delivered_at
    assert [grant] = grants_for_source!(fixture.subscription_id)
    assert grant.status == :revoked
  end

  test "the indexed recovery sweep rediscovers an effect when its job was lost" do
    fixture = create_committed_suspended_effect_fixture!("jc239_effect_lost_job")
    effect = fetch_effect!(fixture.effect_id)
    cursor_start = DateTime.add(effect.updated_at, -1, :microsecond)
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, result} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_subscription_access_effect_recovery_for_system(
                 limit: 1,
                 as_of: as_of,
                 execution_after_updated_at: cursor_start,
                 execution_after_id: "00000000-0000-0000-0000-000000000000",
                 skip_projection: true,
                 skip_effective_execution: true
               )
             end)

    assert result.execution_count == 1
    assert result.failed_count == 0
    assert fetch_effect!(fixture.effect_id).status == :applied
    assert [grant] = grants_for_source!(fixture.subscription_id)
    assert grant.status == :revoked
  end

  test "NON_EFFECTIVE recovery cursor and skip options retain their existing contract" do
    fixture = create_committed_suspended_effect_fixture!("jc246_execution_cursor")
    effect = fetch_effect!(fixture.effect_id)
    cursor_start = DateTime.add(effect.updated_at, -1, :microsecond)
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    base_opts = [
      limit: 1,
      as_of: as_of,
      execution_after_updated_at: cursor_start,
      execution_after_id: "00000000-0000-0000-0000-000000000000",
      skip_projection: true,
      skip_effective_execution: true
    ]

    assert {:ok, skipped} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_subscription_access_effect_recovery_for_system(
                 Keyword.put(base_opts, :skip_execution, true)
               )
             end)

    assert skipped.execution_count == 0
    assert skipped.execution_cursor == nil
    assert fetch_effect!(fixture.effect_id).status == :required

    assert {:ok, recovered} =
             Sandbox.unboxed_run(Repo, fn ->
               Facade.run_subscription_access_effect_recovery_for_system(base_opts)
             end)

    assert recovered.execution_count == 1
    assert recovered.failed_count == 0
    assert recovered.execution_cursor == %{timestamp: effect.updated_at, id: effect.id}
    assert fetch_effect!(fixture.effect_id).status == :applied
  end

  defp create_committed_suspended_effect_fixture!(prefix) do
    fixture = Sandbox.unboxed_run(Repo, fn -> create_suspended_effect_fixture!(prefix) end)
    on_exit(fn -> cleanup_fixture!(fixture) end)
    fixture
  end

  defp create_suspended_effect_fixture!(prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("#{prefix}_#{Ecto.UUID.generate()}")
    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        max_retry_attempts: 0,
        grace_period_days: 0,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    variant_plan = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, order: order, line_item: line_item} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    grant =
      EntitlementGrant
      |> Ash.Changeset.for_create(
        :issue,
        %{
          user_id: customer.id,
          kind: :membership_access,
          scope_key: plan.entitlement_scope_key,
          source_kind: :subscription,
          source_id: subscription.id,
          status: :active,
          valid_from_at: DateTime.add(now, -60, :second),
          valid_to_at: DateTime.add(now, 86_400, :second)
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now)

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    assert {:ok, %{suspended_count: 1}} = Facade.run_due_failed_payment_suspensions_for_system()

    effect =
      AccessEffect
      |> Ash.Query.filter(expr(subscription_id == ^subscription.id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    %{
      customer_id: customer.id,
      effect_id: effect.id,
      grant_id: grant.id,
      line_item_id: line_item.id,
      order_id: order.id,
      plan_id: plan.id,
      product_id: product.id,
      subscription_id: subscription.id,
      variant_id: variant.id,
      variant_plan_id: variant_plan.id
    }
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription_id)
      effect_id = Ecto.UUID.dump!(fixture.effect_id)
      line_item_id = Ecto.UUID.dump!(fixture.line_item_id)
      order_id = Ecto.UUID.dump!(fixture.order_id)
      variant_id = Ecto.UUID.dump!(fixture.variant_id)
      product_id = Ecto.UUID.dump!(fixture.product_id)
      plan_id = Ecto.UUID.dump!(fixture.plan_id)

      Repo.query!("DELETE FROM access_effects WHERE id = $1", [effect_id])
      Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = NULL WHERE id = $1",
        [subscription_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [subscription_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [subscription_id])
      Repo.query!("DELETE FROM order_line_items WHERE id = $1", [line_item_id])
      Repo.query!("DELETE FROM order_adjustments WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM fulfillment_orders WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM payment_intents WHERE order_id = $1", [order_id])
      Repo.query!("DELETE FROM orders WHERE id = $1", [order_id])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE variant_id = $1", [variant_id])
      Repo.query!("DELETE FROM plan_revisions WHERE subscription_plan_id = $1", [plan_id])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [plan_id])
      Repo.query!("SET CONSTRAINTS products_default_variant_id_fkey DEFERRED")
      Repo.query!("DELETE FROM products WHERE id = $1", [product_id])
    end)
  end

  defp fetch_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp grants_for_source!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end
end
