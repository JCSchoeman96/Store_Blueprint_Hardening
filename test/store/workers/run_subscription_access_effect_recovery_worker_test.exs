defmodule Store.Workers.RunSubscriptionAccessEffectRecoveryWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.DirectRepo
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Workers.RunSubscriptionAccessEffectRecoveryWorker

  setup do
    clear_worker_jobs!()
    on_exit(&clear_worker_jobs!/0)
    :ok
  end

  test "a half EFFECTIVE cursor discards the continuation" do
    assert {:discard, _reason} =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "effective_execution_after_updated_at" =>
                   DateTime.to_iso8601(DateTime.utc_now()),
                 "limit" => 1
               }
             )
  end

  test "continuation preserves the three independent cursors and sweep identity" do
    _effective = create_effect_fixture!(:effective)
    non_effective = create_effect_fixture!(:non_effective)
    projection = create_effect_fixture!(:effective)

    Repo.query!("UPDATE subscriptions SET status = 'suspended' WHERE id = $1", [
      Ecto.UUID.dump!(non_effective.subscription.id)
    ])

    Repo.query!(
      "UPDATE access_effects SET status = 'applied', projection_user_ids = ARRAY[$2]::uuid[] WHERE id = $1",
      [Ecto.UUID.dump!(projection.effect.id), Ecto.UUID.dump!(projection.subscription.user_id)]
    )

    assert :ok =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "as_of" => "2099-01-01T00:00:00Z",
                 "limit" => 1,
                 "sweep_id" => "jc245-three-streams"
               }
             )

    assert [job] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)
    assert job.args["sweep_id"] == "jc245-three-streams"
    assert job.args["as_of"] == "2099-01-01T00:00:00Z"
    assert job.args["skip_execution"] == false
    assert job.args["skip_effective_execution"] == false
    assert job.args["skip_projection"] == false
    assert is_binary(job.args["execution_after_updated_at"])
    assert is_binary(job.args["execution_after_id"])
    assert is_binary(job.args["effective_execution_after_updated_at"])
    assert is_binary(job.args["effective_execution_after_id"])
    assert is_binary(job.args["projection_after_inserted_at"])
    assert is_binary(job.args["projection_after_id"])
  end

  test "a sweep with all three streams exhausted does not enqueue a continuation" do
    assert [] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)

    assert :ok =
             perform_job(
               RunSubscriptionAccessEffectRecoveryWorker,
               %{
                 "as_of" => "2099-01-01T00:00:00Z",
                 "limit" => 1,
                 "skip_execution" => true,
                 "skip_effective_execution" => true,
                 "skip_projection" => true
               }
             )

    assert [] = all_enqueued(worker: RunSubscriptionAccessEffectRecoveryWorker)
  end

  defp create_effect_fixture!(disposition) do
    customer =
      SubscriptionsFixtures.create_customer!("jc245_worker_#{Ecto.UUID.generate()}")

    %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc245-worker-#{Ecto.UUID.generate()}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    attrs = %{
      subscription_id: fixture.subscription.id,
      source_version: fixture.subscription.aggregate_version,
      disposition: disposition,
      entitlement_kind: if(disposition == :effective, do: fixture.revision.entitlement_kind),
      entitlement_scope_key:
        if(disposition == :effective, do: fixture.revision.entitlement_scope_key),
      valid_from_at:
        if(disposition == :effective, do: fixture.subscription.current_period_start_at),
      valid_until_at:
        if(disposition == :effective, do: fixture.subscription.current_period_end_at),
      source_order_line_item_id: fixture.line_item.id,
      contract_change_id: fixture.subscription.current_contract_change_id,
      plan_revision_id: fixture.revision.id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)

    fixture
    |> Map.merge(%{
      customer: customer,
      effect: effect,
      plan: plan,
      product: product,
      variant: variant
    })
    |> cleanup_on_exit()
  end

  defp cleanup_on_exit(fixture) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        subscription_id = Ecto.UUID.dump!(fixture.subscription.id)
        line_item_id = Ecto.UUID.dump!(fixture.line_item.id)
        order_id = Ecto.UUID.dump!(fixture.order.id)
        variant_id = Ecto.UUID.dump!(fixture.variant.id)
        product_id = Ecto.UUID.dump!(fixture.product.id)
        plan_id = Ecto.UUID.dump!(fixture.plan.id)
        user_id = Ecto.UUID.dump!(fixture.subscription.user_id)

        Repo.query!("DELETE FROM entitlement_grants WHERE source_id = $1", [subscription_id])
        Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [subscription_id])

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
        Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
      end)
    end)

    fixture
  end

  defp clear_worker_jobs! do
    DirectRepo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1",
      [inspect(RunSubscriptionAccessEffectRecoveryWorker)]
    )
  end
end
