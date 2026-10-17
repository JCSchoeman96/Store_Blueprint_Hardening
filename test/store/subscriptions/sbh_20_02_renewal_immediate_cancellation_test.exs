defmodule Store.Subscriptions.Sbh2002RenewalImmediateCancellationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Repo
  alias Store.Subscriptions.{
    Facade,
    Inputs.QueueSubscriptionPlanChangeInput,
    RenewalAttempt,
    RenewalCollectionAttempt,
    Subscription
  }
  alias Store.SubscriptionsFixtures
  alias Store.Support.Errors.Error
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
  end

  test "cancel-now re-evaluates its original intent after renewal checkpoint B wins" do
    fixture = create_committed_fixture!("b_wins_stale_cancel")
    enable_stripe!()

    parent = self()
    read_barrier = make_ref()
    read_count = :atomics.new(1, [])
    dispatch_barrier = make_ref()
    dispatch_count = :atomics.new(1, [])
    provider_post_count = :atomics.new(1, [])
    cancel_start = make_ref()

    cancel_task =
      Task.async(fn ->
        send(parent, {:cancel_task_ready, self(), cancel_start})

        receive do
          {:start_cancel, ^cancel_start} ->
            Sandbox.unboxed_run(Repo, fn ->
              Facade.cancel_subscription_for_user(
                fixture.customer,
                fixture.subscription_id,
                :now
              )
            end)

          :abort -> :aborted
        end
      end)

    assert_receive {:cancel_task_ready, cancel_task_pid, ^cancel_start}

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(provider_post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    read_handler_id = {__MODULE__, :user_subscription_read, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        read_handler_id,
        [:store, :repo, :query],
        fn _event, _measurements, metadata, config ->
          if self() == config.cancel_task_pid and user_subscription_query?(metadata) do
            read_no = :atomics.add_get(config.read_count, 1, 1)

            if read_no == 1 do
              send(config.owner, {:cancel_user_read, config.barrier})
              barrier = config.barrier

              receive do
                {:release_cancel_user_read, ^barrier} -> :ok
              after
                10_000 -> send(config.owner, {:cancel_user_read_timeout, config.barrier})
              end
            end
          end
        end,
        %{
          owner: parent,
          barrier: read_barrier,
          cancel_task_pid: cancel_task_pid,
          read_count: read_count
        }
      )

    dispatch_handler_id =
      {__MODULE__, :renewal_before_dispatch, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        dispatch_handler_id,
        [:store, :subscriptions, :renewal_charge_dispatch_check],
        fn _event, _measurements, metadata, config ->
          if metadata.subscription_id == config.subscription_id and
               :atomics.exchange(config.once, 1, 1) == 0 do
            send(
              config.owner,
              {:renewal_before_dispatch, config.barrier, metadata.renewal_attempt_id,
               metadata.collection_attempt_id}
            )

            barrier = config.barrier

            receive do
              {:release_renewal_dispatch, ^barrier} -> :ok
            after
              10_000 -> send(config.owner, {:renewal_dispatch_timeout, config.barrier})
            end
          end
        end,
        %{
          owner: parent,
          barrier: dispatch_barrier,
          once: dispatch_count,
          subscription_id: fixture.subscription_id
        }
      )

    on_exit(fn ->
      :telemetry.detach(read_handler_id)
      :telemetry.detach(dispatch_handler_id)
      send(cancel_task.pid, :abort)
      send(cancel_task.pid, {:release_cancel_user_read, read_barrier})
    end)

    send(cancel_task.pid, {:start_cancel, cancel_start})

    assert_receive {:cancel_user_read, ^read_barrier}, 10_000

    assert fixture_subscription_version(fixture.subscription_id) ==
             fixture.initial_aggregate_version

    renewal_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Facade.process_due_subscription_renewal_for_system(fixture.subscription_id,
            now: fixture.now
          )
        end)
      end)

    on_exit(fn ->
      send(renewal_task.pid, {:release_renewal_dispatch, dispatch_barrier})
    end)

    assert_receive {:renewal_before_dispatch, ^dispatch_barrier, renewal_attempt_id,
                    collection_attempt_id}, 10_000

    renewal_snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        %{
          subscription: fetch_subscription!(fixture.subscription_id),
          renewal_attempt: fetch_renewal_attempt!(renewal_attempt_id),
          collection_attempt: fetch_collection_attempt!(collection_attempt_id)
        }
      end)

    assert renewal_snapshot.subscription.aggregate_version ==
             fixture.initial_aggregate_version + 1

    send(cancel_task.pid, {:release_cancel_user_read, read_barrier})
    cancel_result = Task.await(cancel_task, 10_000)

    if match?({:error, %Error{code: "STALE_RECORD"}}, cancel_result) do
      assert {:ok, _canceled} =
               Sandbox.unboxed_run(Repo, fn ->
                 Facade.cancel_subscription_for_user(
                   fixture.customer,
                   fixture.subscription_id,
                   :now
                 )
               end)
    end

    send(renewal_task.pid, {:release_renewal_dispatch, dispatch_barrier})
    assert {:ok, :processed} = Task.await(renewal_task, 10_000)

    canceled = fixture_subscription(fixture.subscription_id)

    assert match?({:ok, %Subscription{status: :canceled, cancel_at_period_end: false}}, cancel_result)
    assert :atomics.get(read_count, 1) == 2
    assert renewal_snapshot.renewal_attempt.id
    assert renewal_snapshot.collection_attempt.renewal_attempt_id ==
             renewal_snapshot.renewal_attempt.id

    assert canceled.status == :canceled
    assert canceled.cancel_at_period_end == false
    assert canceled.aggregate_version == renewal_snapshot.subscription.aggregate_version + 1
    assert :atomics.get(provider_post_count, 1) == 0
  end

  defp create_committed_fixture!(suffix) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        unique = "#{suffix}_#{Ecto.UUID.generate()}"
        customer = SubscriptionsFixtures.create_customer!("jc232_#{unique}")
        %{product: product, variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
        plan = SubscriptionsFixtures.create_subscription_plan!()
        attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
        target_plan = SubscriptionsFixtures.create_subscription_plan!(%{amount_minor: 4_100})
        target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)
        target_revision = SubscriptionsFixtures.create_plan_revision!(target_plan)
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %{subscription: subscription, order: order, line_item: line_item, revision: revision} =
          SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
            provider_billing_ref: "pm_jc232_#{unique}",
            started_at: DateTime.add(now, -40 * 86_400, :second)
          })

        {:ok, change_input} =
          QueueSubscriptionPlanChangeInput.new(%{
            "subscription_id" => subscription.id,
            "subscription_plan_id" => target_plan.id
          })

        {:ok, queued_subscription} =
          Facade.queue_subscription_plan_change_for_user(
            customer,
            subscription.id,
            change_input
          )

        %{
          attachment_id: attachment.id,
          customer: customer,
          customer_id: customer.id,
          initial_aggregate_version: queued_subscription.aggregate_version,
          line_item_id: line_item.id,
          now: now,
          order_id: order.id,
          plan_id: plan.id,
          product_id: product.id,
          revision_id: revision.id,
          subscription_id: subscription.id,
          target_attachment_id: target_attachment.id,
          target_plan_id: target_plan.id,
          target_revision_id: target_revision.id
        }
      end)

    on_exit(fn -> cleanup_committed_fixture!(fixture) end)
    fixture
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      sub_id = Ecto.UUID.dump!(fixture.subscription_id)
      user_id = Ecto.UUID.dump!(fixture.customer_id)

      Repo.query!(
        "DELETE FROM oban_jobs WHERE args->>'subscription_id' = $1 OR args->>'order_id' IN (SELECT id::text FROM orders WHERE user_id = $2)",
        [fixture.subscription_id, user_id]
      )

      Repo.query!(
        "DELETE FROM email_outboxes WHERE subscription_id = $1 OR order_id IN (SELECT id FROM orders WHERE user_id = $2)",
        [sub_id, user_id]
      )

      Repo.query!(
        "DELETE FROM refunds WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_applications WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)",
        [user_id]
      )

      Repo.query!(
        "DELETE FROM payment_outcome_certifications WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE renewal_collection_attempts DISABLE TRIGGER renewal_collection_attempts_guard")

        Repo.query!(
          "DELETE FROM renewal_collection_attempts WHERE renewal_attempt_id IN (SELECT id FROM renewal_attempts WHERE subscription_id = $1)",
          [sub_id]
        )

        Repo.query!("ALTER TABLE renewal_collection_attempts ENABLE TRIGGER renewal_collection_attempts_guard")
      end)

      Repo.query!(
        "DELETE FROM payment_attempts WHERE payment_intent_id IN (SELECT id FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1))",
        [user_id]
      )

      Repo.query!("DELETE FROM renewal_attempts WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM access_effects WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM entitlement_grants WHERE source_kind = 'subscription' AND source_id = $1", [sub_id])
      Repo.query!("DELETE FROM subscription_items WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM contract_changes WHERE subscription_id = $1", [sub_id])
      Repo.query!("DELETE FROM subscriptions WHERE id = $1", [sub_id])

      Repo.query!("DELETE FROM payment_intents WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
      Repo.query!("DELETE FROM order_line_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = $1)", [user_id])
      Repo.query!("DELETE FROM orders WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM stored_payment_methods WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [Ecto.UUID.dump!(fixture.revision_id)])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [Ecto.UUID.dump!(fixture.attachment_id)])
      Repo.query!("DELETE FROM plan_revisions WHERE id = $1", [Ecto.UUID.dump!(fixture.target_revision_id)])
      Repo.query!("DELETE FROM variant_subscription_plans WHERE id = $1", [Ecto.UUID.dump!(fixture.target_attachment_id)])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [Ecto.UUID.dump!(fixture.plan_id)])
      Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [Ecto.UUID.dump!(fixture.target_plan_id)])
      Repo.query!("DELETE FROM products WHERE id = $1", [Ecto.UUID.dump!(fixture.product_id)])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    end)
  end

  defp user_subscription_query?(metadata) do
    source = metadata |> Map.get(:source) |> to_string()
    query = metadata |> Map.get(:query, "") |> String.downcase()

    case String.split(query, "where", parts: 2) do
      [_select, predicate] ->
        source == "subscriptions" and String.contains?(predicate, "user_id")

      _ ->
        false
    end
  end

  defp fixture_subscription_version(subscription_id) do
    fixture_subscription(subscription_id).aggregate_version
  end

  defp fixture_subscription(subscription_id) do
    Sandbox.unboxed_run(Repo, fn -> fetch_subscription!(subscription_id) end)
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_renewal_attempt!(attempt_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_collection_attempt!(collection_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(id == ^collection_attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp enable_stripe! do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )
  end
end
