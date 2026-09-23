defmodule Store.Subscriptions.OptimisticAggregateVersionTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.Facade.StaleWrite
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error

  test "a stale lifecycle writer cannot overwrite the committed transition" do
    subscription = create_subscription!()
    writer_a = reload_subscription!(subscription.id)
    writer_b = reload_subscription!(subscription.id)
    initial_version = aggregate_version(writer_a)

    assert initial_version == aggregate_version(writer_b)

    assert {:ok, past_due} =
             update_subscription(writer_a, :mark_past_due_transition, %{
               billing_status_reason: "PAYMENT_FAILED",
               dunning_attempt_count: 1
             })

    stale_result =
      update_subscription(writer_b, :cancel_now_transition, %{
        canceled_reason: "stale_writer"
      })

    assert stale_record_error?(stale_result)
    assert aggregate_version(past_due) == initial_version + 1

    authoritative = reload_subscription!(subscription.id)
    assert authoritative.status == :past_due
    assert authoritative.canceled_reason == nil
    assert aggregate_version(authoritative) == initial_version + 1
  end

  test "a stale ACTIVE to ACTIVE extension cannot replace period or commercial fields" do
    subscription = create_subscription!()
    writer_a = reload_subscription!(subscription.id)
    writer_b = reload_subscription!(subscription.id)
    initial_version = aggregate_version(writer_a)

    winner_period_end =
      DateTime.add(writer_a.current_period_end_at, 30 * 24 * 60 * 60, :second)

    assert {:ok, winner} =
             update_subscription(writer_a, :extend_period, %{
               current_period_end_at: winner_period_end,
               next_renewal_at: winner_period_end,
               renewal_amount_minor: 1_500
             })

    assert winner.status == :active

    stale_period_end =
      DateTime.add(writer_b.current_period_end_at, 60 * 24 * 60 * 60, :second)

    stale_result =
      update_subscription(writer_b, :extend_period, %{
        current_period_end_at: stale_period_end,
        next_renewal_at: stale_period_end,
        renewal_amount_minor: 9_900
      })

    assert stale_record_error?(stale_result)
    assert aggregate_version(winner) == initial_version + 1

    authoritative = reload_subscription!(subscription.id)
    assert authoritative.current_period_end_at == winner_period_end
    assert authoritative.next_renewal_at == winner_period_end
    assert authoritative.renewal_amount_minor == 1_500
    assert aggregate_version(authoritative) == initial_version + 1
  end

  test "a stale non-state queued change cannot replace the committed change" do
    subscription = create_subscription!()
    writer_a = reload_subscription!(subscription.id)
    writer_b = reload_subscription!(subscription.id)
    initial_version = aggregate_version(writer_a)
    effective_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, winner} =
             update_subscription(writer_a, :queue_change, %{
               pending_renewal_amount_minor: 1_700,
               pending_renewal_currency: "USD",
               change_effective_at: effective_at
             })

    stale_result =
      update_subscription(writer_b, :queue_change, %{
        pending_renewal_amount_minor: 8_800,
        pending_renewal_currency: "EUR",
        change_effective_at: DateTime.add(effective_at, 24 * 60 * 60, :second)
      })

    assert stale_record_error?(stale_result)
    assert aggregate_version(winner) == initial_version + 1

    authoritative = reload_subscription!(subscription.id)
    assert authoritative.pending_renewal_amount_minor == 1_700
    assert authoritative.pending_renewal_currency == "USD"
    assert authoritative.change_effective_at == effective_at
    assert aggregate_version(authoritative) == initial_version + 1
  end

  test "a Subscription stale write normalizes to the existing STALE_RECORD code" do
    subscription = create_subscription!()
    writer_a = reload_subscription!(subscription.id)
    writer_b = reload_subscription!(subscription.id)

    assert {:ok, _winner} =
             update_subscription(writer_a, :set_provider_billing_reference, %{
               provider_customer_ref: "cus_normalizer_winner",
               provider_billing_ref: "pm_normalizer_winner"
             })

    stale_result =
      update_subscription(writer_b, :set_provider_billing_reference, %{
        provider_customer_ref: "cus_normalizer_stale",
        provider_billing_ref: "pm_normalizer_stale"
      })

    assert stale_record_error?(stale_result)

    assert {:error, %Error{code: "STALE_RECORD"}} =
             StaleWrite.normalize_update_result(stale_result)
  end

  test "every material Subscription action rejects a stale version and increments once" do
    actions = [
      {:activate_now, :pending},
      {:mark_past_due_transition, :active},
      {:cancel_at_period_end_transition, :active},
      {:cancel_now_transition, :active},
      {:extend_period, :active},
      {:queue_change, :active},
      {:mark_expired_transition, :active},
      {:set_provider_billing_reference, :active}
    ]

    for {action, status} <- actions do
      subscription = create_subscription!(status: status)
      writer_a = reload_subscription!(subscription.id)
      writer_b = reload_subscription!(subscription.id)
      initial_version = aggregate_version(writer_a)
      {attrs_a, attrs_b} = action_attributes(action, writer_a, writer_b)

      assert {:ok, winner} = update_subscription(writer_a, action, attrs_a),
             "#{action} must accept the loaded aggregate version"

      stale_result = update_subscription(writer_b, action, attrs_b)

      assert stale_record_error?(stale_result),
             "#{action} must reject a write loaded from the stale aggregate version"

      assert aggregate_version(winner) == initial_version + 1,
             "#{action} must increment the aggregate version once"

      authoritative = reload_subscription!(subscription.id)

      assert aggregate_version(authoritative) == initial_version + 1,
             "#{action} must leave the winner's single version increment durable"
    end
  end

  test "two writers released together commit one material mutation" do
    fixture = create_committed_subscription_fixture!()
    on_exit(fn -> delete_committed_subscription_fixture!(fixture) end)
    initial_version = fixture.aggregate_version
    parent = self()

    tasks =
      [
        %{provider_customer_ref: "cus_writer_a", provider_billing_ref: "pm_writer_a"},
        %{provider_customer_ref: "cus_writer_b", provider_billing_ref: "pm_writer_b"}
      ]
      |> Enum.map(fn attrs ->
        Task.async(fn ->
          Sandbox.unboxed_run(Store.Repo, fn ->
            writer = reload_subscription!(fixture.subscription_id)
            {:ok, %{rows: [[backend_pid]]}} = Store.Repo.query("SELECT pg_backend_pid()")

            send(
              parent,
              {:subscription_writer_ready, self(), backend_pid, aggregate_version(writer)}
            )

            receive do
              :write -> update_subscription(writer, :set_provider_billing_reference, attrs)
            end
          end)
        end)
      end)

    backend_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:subscription_writer_ready, _pid, backend_pid, ^initial_version}
        backend_pid
      end)

    assert length(Enum.uniq(backend_pids)) == 2

    Enum.each(tasks, &send(&1.pid, :write))

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    successes = Enum.filter(results, &match?({:ok, _}, &1))
    stale_writes = Enum.filter(results, &stale_record_error?/1)

    assert length(successes) == 1
    assert length(stale_writes) == 1

    {:ok, winner} = hd(successes)

    authoritative =
      Sandbox.unboxed_run(Store.Repo, fn -> reload_subscription!(fixture.subscription_id) end)

    assert authoritative.provider_customer_ref == winner.provider_customer_ref
    assert authoritative.provider_billing_ref == winner.provider_billing_ref
    assert aggregate_version(authoritative) == initial_version + 1
  end

  test "a replayed no-op action does not advance the aggregate version" do
    subscription = create_subscription!()
    initial_version = aggregate_version(subscription)

    assert {:ok, first} =
             update_subscription(subscription, :cancel_at_period_end_transition, %{})

    assert first.cancel_at_period_end
    assert aggregate_version(first) == initial_version + 1

    assert {:ok, replayed} =
             update_subscription(first, :cancel_at_period_end_transition, %{})

    assert replayed.cancel_at_period_end
    assert aggregate_version(replayed) == initial_version + 1
    assert aggregate_version(reload_subscription!(subscription.id)) == initial_version + 1
  end

  defp create_subscription!(opts \\ []) do
    customer =
      SubscriptionsFixtures.create_customer!("sbh_20_01_#{System.unique_integer([:positive])}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        status: Keyword.get(opts, :status, :active)
      })

    subscription
  end

  defp create_committed_subscription_fixture! do
    Sandbox.unboxed_run(Store.Repo, fn ->
      customer =
        SubscriptionsFixtures.create_customer!(
          "sbh_20_01_race_#{System.unique_integer([:positive])}"
        )

      %{product: product, variant: variant} =
        SubscriptionsFixtures.create_subscription_sellable!()

      plan = SubscriptionsFixtures.create_subscription_plan!()
      attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

      %{
        subscription: subscription,
        order: order,
        line_item: line_item,
        revision: revision
      } =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{})

      %{
        aggregate_version: aggregate_version(subscription),
        attachment_id: attachment.id,
        customer_id: customer.id,
        line_item_id: line_item.id,
        order_id: order.id,
        plan_id: plan.id,
        product_id: product.id,
        revision_id: revision.id,
        subscription_id: subscription.id
      }
    end)
  end

  defp delete_committed_subscription_fixture!(fixture) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      delete_by_id!(:subscriptions, fixture.subscription_id)
      delete_by_id!(:order_line_items, fixture.line_item_id)
      delete_by_id!(:payment_intents, fixture.order_id, :order_id)
      delete_by_id!(:plan_revisions, fixture.revision_id)
      delete_by_id!(:variant_subscription_plans, fixture.attachment_id)
      delete_by_id!(:subscription_plans, fixture.plan_id)
      delete_by_id!(:orders, fixture.order_id)
      delete_by_id!(:products, fixture.product_id)
      delete_by_id!(:users, fixture.customer_id)
    end)
  end

  defp delete_by_id!(table, id, field \\ :id)
       when table in [
              :subscriptions,
              :order_line_items,
              :payment_intents,
              :plan_revisions,
              :variant_subscription_plans,
              :subscription_plans,
              :orders,
              :products,
              :users
            ] and field in [:id, :order_id] do
    Store.Repo.query!("DELETE FROM #{table} WHERE #{field} = $1", [Ecto.UUID.dump!(id)])
  end

  defp reload_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp update_subscription(subscription, action, attrs) do
    subscription
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp action_attributes(:activate_now, _writer_a, _writer_b) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {
      %{
        started_at: now,
        current_period_start_at: now,
        current_period_end_at: DateTime.add(now, 30 * 24 * 60 * 60, :second),
        next_renewal_at: DateTime.add(now, 30 * 24 * 60 * 60, :second)
      },
      %{
        started_at: DateTime.add(now, 1, :second),
        current_period_start_at: DateTime.add(now, 1, :second),
        current_period_end_at: DateTime.add(now, 31 * 24 * 60 * 60, :second),
        next_renewal_at: DateTime.add(now, 31 * 24 * 60 * 60, :second)
      }
    }
  end

  defp action_attributes(:mark_past_due_transition, _writer_a, _writer_b) do
    {%{billing_status_reason: "PAYMENT_FAILED", dunning_attempt_count: 1},
     %{billing_status_reason: "PAYMENT_AUTHENTICATION_REQUIRED", dunning_attempt_count: 2}}
  end

  defp action_attributes(:cancel_at_period_end_transition, _writer_a, _writer_b),
    do: {%{}, %{}}

  defp action_attributes(:cancel_now_transition, _writer_a, _writer_b),
    do: {%{canceled_reason: "winner"}, %{canceled_reason: "stale"}}

  defp action_attributes(:extend_period, writer_a, writer_b) do
    winner_period_end =
      DateTime.add(writer_a.current_period_end_at, 30 * 24 * 60 * 60, :second)

    stale_period_end =
      DateTime.add(writer_b.current_period_end_at, 60 * 24 * 60 * 60, :second)

    {
      %{
        current_period_end_at: winner_period_end,
        next_renewal_at: winner_period_end,
        renewal_amount_minor: 1_500
      },
      %{
        current_period_end_at: stale_period_end,
        next_renewal_at: stale_period_end,
        renewal_amount_minor: 9_900
      }
    }
  end

  defp action_attributes(:queue_change, _writer_a, _writer_b) do
    effective_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {
      %{
        pending_renewal_amount_minor: 1_700,
        pending_renewal_currency: "USD",
        change_effective_at: effective_at
      },
      %{
        pending_renewal_amount_minor: 8_800,
        pending_renewal_currency: "EUR",
        change_effective_at: DateTime.add(effective_at, 24 * 60 * 60, :second)
      }
    }
  end

  defp action_attributes(:mark_expired_transition, _writer_a, _writer_b),
    do: {%{canceled_reason: "winner"}, %{canceled_reason: "stale"}}

  defp action_attributes(:set_provider_billing_reference, _writer_a, _writer_b) do
    {
      %{provider_customer_ref: "cus_winner", provider_billing_ref: "pm_winner"},
      %{provider_customer_ref: "cus_stale", provider_billing_ref: "pm_stale"}
    }
  end

  defp aggregate_version(subscription), do: Map.get(subscription, :aggregate_version) || 1

  defp stale_record_error?({:error, %Ash.Error.Invalid{errors: errors}}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false
end
