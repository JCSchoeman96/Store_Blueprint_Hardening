defmodule Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorkerTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.SubscriptionsFixtures
  alias Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorker

  test "perform runs reconciliation and accepts bounded limit" do
    as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert :ok =
             perform_job(
               ReconcileSubscriptionAccessEffectTargetOrderWorker,
               %{
                 "as_of" => DateTime.to_iso8601(as_of),
                 "limit" => 25
               }
             )
  end

  test "full candidate page enqueues one immutable cursor continuation" do
    first = create_candidate!()
    second = create_candidate!()
    as_of = DateTime.add(second.inserted_at, 1, :second)
    after_inserted_at = DateTime.add(first.inserted_at, -1, :second)

    assert :ok =
             perform_job(
               ReconcileSubscriptionAccessEffectTargetOrderWorker,
               %{
                 "as_of" => DateTime.to_iso8601(as_of),
                 "after_inserted_at" => DateTime.to_iso8601(after_inserted_at),
                 "after_id" => "00000000-0000-7000-8000-000000000000",
                 "limit" => 1
               }
             )

    assert [job] = all_enqueued(worker: ReconcileSubscriptionAccessEffectTargetOrderWorker)
    assert job.args["as_of"] == DateTime.to_iso8601(as_of)
    assert job.args["after_id"] == first.id

    assert DateTime.from_iso8601(job.args["after_inserted_at"]) ==
             {:ok, first.inserted_at, 0}

    refute Map.has_key?(job.args, "effective_after_updated_at")
    refute Map.has_key?(job.args, "non_effective_after_updated_at")
    assert second.id
  end

  test "invalid cursor discards the job" do
    assert {:discard, _} =
             perform_job(
               ReconcileSubscriptionAccessEffectTargetOrderWorker,
               %{"limit" => "not-a-number"}
             )
  end

  defp create_candidate! do
    customer = SubscriptionsFixtures.create_customer!("f05_worker_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f05-worker"
      })

    fixture = SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
    subscription = fixture.subscription
    revision = fixture.revision

    assert {:ok, input} =
             EstablishAccessEffectInput.new(%{
               subscription_id: subscription.id,
               source_version: subscription.aggregate_version,
               disposition: :effective,
               entitlement_kind: revision.entitlement_kind,
               entitlement_scope_key: revision.entitlement_scope_key,
               valid_from_at: subscription.current_period_start_at,
               valid_until_at: subscription.current_period_end_at,
               source_order_line_item_id: subscription.source_order_line_item_id,
               contract_change_id: subscription.current_contract_change_id,
               plan_revision_id: revision.id
             })

    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)

    %{effect | inserted_at: inserted_at!(effect.id)}
  end

  defp inserted_at!(effect_id) do
    %{rows: [[inserted_at]]} =
      Repo.query!("SELECT inserted_at FROM access_effects WHERE id = $1", [
        Ecto.UUID.dump!(effect_id)
      ])

    DateTime.from_naive!(inserted_at, "Etc/UTC")
  end
end
