defmodule Store.Subscriptions.Sbh2005SuccessVsLateFailureDunningTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Comms.EmailOutbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Facade, as: EntitlementsFacade
  alias Store.Orders.Order
  alias Store.Payments.PaymentIntent
  alias Store.Payments.PaymentOutcomeResolver
  alias Store.Payments.Types.ProviderObservation

  alias Store.Subscriptions.{
    Facade,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.Support.Telemetry.RepoStats
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "late provider failure does not fail an attempt after paid commercial apply", context do
    %{attempt: attempt, subscription: subscription} =
      late_failure_after_paid_application!(
        "jc235_paid_apply_failure",
        context.sandbox_owners,
        plan_attributes: %{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "jc235_paid_apply"
        }
      )

    assert attempt.status == :succeeded
    assert is_nil(attempt.failure_code)
    assert subscription.status == :active
    assert subscription.dunning_attempt_count == 0
    assert is_nil(subscription.next_retry_at)

    assert [%EntitlementGrant{status: :active, valid_to_at: valid_to_at}] =
             grants_for(subscription.id)

    assert DateTime.compare(valid_to_at, attempt.period_end_at) == :eq
    assert count_collections_for_attempt(attempt.id) == 1
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "failure persistence error stops before Subscription dunning" do
    %{task: task, barrier: barrier, attempt: attempt, subscription: subscription} =
      start_due_charge_waiting_for_failure!("jc235_attempt_write_error")

    trigger_suffix = System.unique_integer([:positive])
    trigger_name = "jc235_reject_attempt_failure_#{trigger_suffix}"
    function_name = "jc235_reject_attempt_failure_fn_#{trigger_suffix}"

    Store.Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.id::text = current_setting('store.jc235_fail_attempt_id', true)
        AND NEW.status = 'failed' THEN
        RAISE EXCEPTION 'injected JC-235 RenewalAttempt failure write error';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Store.Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF status ON renewal_attempts
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    assert {:ok, %{rows: [[attempt_id]]}} =
             Store.Repo.query(
               "SELECT set_config('store.jc235_fail_attempt_id', $1, false)",
               [attempt.id]
             )

    assert attempt_id == attempt.id

    before_subscription = fetch_subscription!(subscription.id)
    Agent.update(barrier, &Map.put(&1, :release_charge?, true))

    assert {:error, %{code: "INTERNAL_ERROR"}} = Task.await(task, 10_000)
    assert fetch_attempt!(attempt.id).status == :processing
    assert fetch_subscription!(subscription.id) == before_subscription

    Store.Repo.query!("SELECT set_config('store.jc235_fail_attempt_id', '', false)")
    Store.Repo.query!("DROP TRIGGER #{trigger_name} ON renewal_attempts")
    Store.Repo.query!("DROP FUNCTION #{function_name}()")
  end

  test "a stale dunning writer re-evaluates to a success no-op", context do
    %{result: result} =
      late_failure_after_paid_application!("jc235_stale_dunning_writer", context.sandbox_owners)

    assert {:ok, :processed} = result
  end

  test "subscription dunning write failure rolls back the attempt failure" do
    fixture = start_due_charge_waiting_for_failure!("jc235_dunning_write_error")
    before_subscription = fetch_subscription!(fixture.subscription.id)

    {trigger_name, function_name} =
      install_status_rejection_trigger!("subscriptions", fixture.subscription.id, "past_due")

    on_exit(fn -> drop_trigger_and_function!("subscriptions", trigger_name, function_name) end)

    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))

    assert {:error, %{code: "INTERNAL_ERROR"}} = Task.await(fixture.task, 10_000)
    assert fetch_attempt!(fixture.attempt.id).status == :processing
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
  end

  test "authentication-required settlement keeps the collection unresolved and records dunning" do
    fixture =
      start_due_charge_waiting_for_failure!("jc235_requires_action",
        provider_response: :requires_action
      )

    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))

    assert {:ok, :processed} = Task.await(fixture.task, 10_000)

    attempt = fetch_attempt!(fixture.attempt.id)
    subscription = fetch_subscription!(fixture.subscription.id)
    collection = successful_or_current_collection!(attempt.id)

    assert attempt.status == :failed
    assert attempt.failure_code == "PAYMENT_AUTHENTICATION_REQUIRED"
    assert subscription.status == :past_due
    assert subscription.billing_status_reason == "PAYMENT_AUTHENTICATION_REQUIRED"
    assert subscription.dunning_attempt_count == 1
    assert %DateTime{} = subscription.past_due_since_at
    assert %DateTime{} = subscription.next_retry_at
    assert collection.financial_outcome == :requires_action
  end

  test "unresolved provider outcome keeps the attempt processing without dunning" do
    fixture =
      start_due_charge_waiting_for_failure!("jc235_payment_unresolved",
        provider_response: :unresolved
      )

    before_subscription = fetch_subscription!(fixture.subscription.id)
    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))

    assert {:ok, :processed} = Task.await(fixture.task, 10_000)
    assert fetch_attempt!(fixture.attempt.id).status == :processing
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
    assert successful_or_current_collection!(fixture.attempt.id).financial_outcome == :unresolved
  end

  test "authentication-required dunning failure rolls back and emits no email" do
    fixture =
      start_due_charge_waiting_for_failure!("jc235_requires_action_rollback",
        provider_response: :requires_action
      )

    before_subscription = fetch_subscription!(fixture.subscription.id)

    parent = self()
    handler_id = "jc235_auth_rollback_dunning_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, metadata, owner -> send(owner, {:jc235_dunning, metadata}) end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {trigger_name, function_name} =
      install_status_rejection_trigger!("subscriptions", fixture.subscription.id, "past_due")

    on_exit(fn -> drop_trigger_and_function!("subscriptions", trigger_name, function_name) end)

    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))

    assert {:error, %{code: "INTERNAL_ERROR"}} = Task.await(fixture.task, 10_000)
    assert fetch_attempt!(fixture.attempt.id).status == :processing
    assert fetch_subscription!(fixture.subscription.id) == before_subscription
    assert count_authentication_emails(fixture.attempt.order_id) == 0
    refute_receive {:jc235_dunning, _metadata}, 0
  end

  test "failure-first authoritative success recovers the exact original renewal" do
    fixture = start_due_charge_waiting_for_failure!("jc235_failure_first_success")
    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))

    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} = Task.await(fixture.task, 10_000)
    failed_subscription = fetch_subscription!(fixture.subscription.id)
    failed_attempt = fetch_attempt!(fixture.attempt.id)
    assert failed_attempt.status == :failed
    assert failed_subscription.status == :past_due
    assert failed_subscription.dunning_attempt_count == 1
    original_period_end = failed_attempt.period_end_at

    record_authoritative_success!(fixture.payment_intent)
    collection = successful_collection!(fixture.attempt.id)
    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} = reconcile_handoff(handoff)

    recovered_subscription = fetch_subscription!(fixture.subscription.id)
    assert recovered_subscription.status == :active
    assert recovered_subscription.current_period_end_at == original_period_end
    assert recovered_subscription.dunning_attempt_count == 0
    assert is_nil(recovered_subscription.next_retry_at)
    applied_aggregate_version = recovered_subscription.aggregate_version
    assert fetch_attempt!(fixture.attempt.id).status == :succeeded
    assert count_attempts_for_subscription(fixture.subscription.id) == 1
    assert count_collections_for_attempt(fixture.attempt.id) == 1

    assert {:ok, :noop} = reconcile_handoff(handoff)

    replayed_subscription = fetch_subscription!(fixture.subscription.id)
    assert replayed_subscription.current_period_end_at == original_period_end
    assert replayed_subscription.aggregate_version == applied_aggregate_version

    assert count_attempts_for_subscription(fixture.subscription.id) == 1
    assert count_collections_for_attempt(fixture.attempt.id) == 1
  end

  test "failure-first authoritative success recovers a suspended same renewal" do
    fixture =
      start_due_charge_waiting_for_failure!("jc235_suspended_failure_first_success",
        plan_attributes: %{
          max_retry_attempts: 0,
          entitlement_kind: :membership_access,
          entitlement_scope_key: "jc235_suspended_recovery"
        }
      )

    Agent.update(fixture.barrier, &Map.put(&1, :release_charge?, true))
    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} = Task.await(fixture.task, 10_000)
    assert fetch_subscription!(fixture.subscription.id).status == :suspended

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
             grants_for(fixture.subscription.id)

    attempt = fetch_attempt!(fixture.attempt.id)
    record_authoritative_success!(fixture.payment_intent)
    collection = successful_collection!(attempt.id)
    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    assert {:ok, :reconciled} = reconcile_handoff(handoff)

    subscription = fetch_subscription!(fixture.subscription.id)
    assert subscription.status == :active
    assert subscription.current_period_end_at == attempt.period_end_at
    assert subscription.dunning_attempt_count == 0

    assert [%EntitlementGrant{status: :active, valid_to_at: valid_to_at}] =
             grants_for(subscription.id)

    assert DateTime.compare(valid_to_at, attempt.period_end_at) == :eq
    assert fetch_attempt!(attempt.id).status == :succeeded
    assert count_attempts_for_subscription(subscription.id) == 1
  end

  test "reversal evidence is not classified as an ordinary terminal failure" do
    for {raw_status, outcome} <- [
          {"charge.refunded", :reversal_observation},
          {"charge.dispute.created", :unknown_or_contradictory}
        ] do
      observation = %ProviderObservation{
        provider: :stripe,
        provider_reference: "pi_jc235_reversal",
        provider_reference_kind: :payment_intent,
        provider_transaction_id: "pi_jc235_reversal",
        local_payment_intent_id: "intent-jc235-reversal",
        observation_source: :verification,
        normalized_outcome: outcome,
        raw_provider_status: raw_status,
        amount_minor: 1_999,
        currency: "USD",
        provider_environment: "test",
        observed_at: DateTime.utc_now()
      }

      assert {:ok, :reconciliation_required} =
               PaymentOutcomeResolver.resolve(
                 %{id: "intent-jc235-reversal"},
                 observation,
                 provider_finality: :terminal_non_success
               )
    end
  end

  test "ordinary failure settlement query count stays bounded" do
    fixture =
      prepare_due_charge_fixture!("jc235_failure_query_shape",
        release_charge?: true
      )

    {result, stats} = RepoStats.capture(fixture.run)

    IO.puts("JC-235 ordinary renewal failure query_count=#{stats.query_count}")
    assert {:error, %{code: "PAYMENT_PROVIDER_DOWN"}} = result
    assert stats.query_count > 0
    assert stats.query_count <= 65
    assert fetch_subscription!(fixture.subscription.id).status == :past_due
    assert fetch_attempt_for_subscription!(fixture.subscription.id).status == :failed
  end

  defp late_failure_after_paid_application!(token, sandbox_owners, opts \\ []) do
    fixture = start_due_charge_waiting_for_failure!(token, opts)
    %{attempt: attempt, order: order, payment_intent: payment_intent, barrier: barrier} = fixture

    record_authoritative_success!(payment_intent)
    collection = successful_collection!(attempt.id)
    {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)

    parent = self()
    crash_once = :atomics.new(1, [])
    handler_id = "jc235_crash_after_apply_#{System.unique_integer([:positive])}"
    dunning_handler_id = "jc235_dunning_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :paid_renewal_access_sync],
        fn _event, _measurements, _metadata, state ->
          if :atomics.compare_exchange(state, 1, 0, 1) == :ok do
            send(parent, {:jc235_paid_apply_committed, self()})
            Process.exit(self(), :kill)
          end
        end,
        crash_once
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        dunning_handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, metadata, owner ->
          send(owner, {:jc235_dunning, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(dunning_handler_id) end)

    {reconciliation, monitor} =
      spawn_monitor(fn ->
        Facade.reconcile_paid_subscription_renewal_for_system(
          order.id,
          renewal_attempt_id: attempt.id,
          collection_attempt_id: handoff.collection_attempt_id,
          payment_intent_id: handoff.payment_intent_id
        )
      end)

    :ok = Sandbox.allow(Store.Repo, sandbox_owners[Store.Repo], reconciliation)
    :ok = Sandbox.allow(Store.DirectRepo, sandbox_owners[Store.DirectRepo], reconciliation)
    assert_receive {:jc235_paid_apply_committed, ^reconciliation}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^reconciliation, :killed}, 1_000

    applied_subscription = fetch_subscription!(fixture.subscription.id)
    assert applied_subscription.current_period_end_at == attempt.period_end_at
    assert fetch_attempt!(attempt.id).status == :processing
    assert grants_for(fixture.subscription.id) == fixture.grants_before_apply

    Agent.update(barrier, &Map.put(&1, :release_charge?, true))
    result = Task.await(fixture.task, 10_000)

    %{
      result: result,
      attempt: fetch_attempt!(attempt.id),
      subscription: fetch_subscription!(fixture.subscription.id),
      grants_before_apply: fixture.grants_before_apply
    }
  end

  defp start_due_charge_waiting_for_failure!(token, opts \\ []) do
    fixture = prepare_due_charge_fixture!(token, opts)

    task = Task.async(fixture.run)

    wait_until(fn -> match?(%{started?: true}, Agent.get(fixture.barrier, & &1)) end)
    attempt = fetch_attempt_for_subscription!(fixture.subscription.id)
    order = fetch_order!(attempt.order_id)
    payment_intent = fetch_payment_intent!(attempt.payment_intent_id)

    Map.merge(fixture, %{
      task: task,
      attempt: attempt,
      order: order,
      payment_intent: payment_intent
    })
  end

  defp prepare_due_charge_fixture!(token, opts) do
    customer = SubscriptionsFixtures.create_customer!(token)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(Keyword.get(opts, :plan_attributes, %{}))

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{token}",
        started_at: DateTime.add(now, -86_410, :second),
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    if plan.entitlement_kind == :membership_access do
      {:ok, _grant} =
        EntitlementsFacade.issue_subscription_entitlement_for_system(subscription, plan)
    end

    grants_before_apply = grants_for(subscription.id)

    release_charge? = Keyword.get(opts, :release_charge?, false)

    {:ok, barrier} =
      Agent.start_link(fn -> %{started?: false, release_charge?: release_charge?} end)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      Agent.update(barrier, &Map.put(&1, :started?, true))

      wait_until(fn ->
        match?(%{release_charge?: true}, Agent.get(barrier, & &1))
      end)

      respond_to_charge(conn, params, Keyword.get(opts, :provider_response, :provider_down))
    end)

    %{
      barrier: barrier,
      subscription: subscription,
      plan: plan,
      now: now,
      grants_before_apply: grants_before_apply,
      run: fn -> Facade.process_due_subscription_renewal_for_system(subscription.id, now: now) end
    }
  end

  defp respond_to_charge(conn, _params, :provider_down) do
    conn
    |> Plug.Conn.put_status(500)
    |> StripeAPIStub.json_response(%{"error" => %{"message" => "late provider failure"}})
  end

  defp respond_to_charge(conn, params, :terminal_failure) do
    StripeAPIStub.payment_intent_error(
      conn,
      params,
      "failed",
      "card_declined",
      "renewal payment failed"
    )
  end

  defp respond_to_charge(conn, params, :requires_action) do
    payment_intent =
      StripeAPIStub.payment_intent_response(params, %{
        "status" => "requires_action",
        "next_action" => %{
          "redirect_to_url" => %{"url" => "https://payments.example.test/authenticate/jc235"}
        }
      })

    conn
    |> Plug.Conn.put_status(402)
    |> StripeAPIStub.json_response(%{
      "error" => %{
        "code" => "authentication_required",
        "message" => "customer authentication is required",
        "payment_intent" => payment_intent
      }
    })
  end

  defp respond_to_charge(conn, params, :unresolved) do
    response = StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
    StripeAPIStub.json_response(conn, response)
  end

  defp record_authoritative_success!(payment_intent) do
    assert {:ok, %{outcome: :authoritative_success}} =
             Store.Payments.record_and_apply_payment_observation_for_system(
               payment_intent,
               %ProviderObservation{
                 provider: payment_intent.provider,
                 provider_reference: payment_intent.provider_request_reference,
                 provider_reference_kind: :transaction_reference,
                 provider_transaction_id: "pi_jc235_success_#{payment_intent.id}",
                 local_payment_intent_id: payment_intent.id,
                 observation_source: :verification,
                 normalized_outcome: :authoritative_success,
                 raw_provider_status: "succeeded",
                 amount_minor: payment_intent.amount_received_minor,
                 currency: payment_intent.currency,
                 provider_environment: "test",
                 observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               }
             )
  end

  defp successful_collection!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(
      expr(renewal_attempt_id == ^attempt_id and financial_outcome == :verified_success)
    )
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp wait_until(predicate, attempts \\ 200) do
    if predicate.() or attempts <= 0 do
      :ok
    else
      Process.sleep(5)
      wait_until(predicate, attempts - 1)
    end
  end

  defp fetch_attempt_for_subscription!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(id), do: read_one!(Subscription, id, Store.Subscriptions)
  defp fetch_attempt!(id), do: read_one!(RenewalAttempt, id, Store.Subscriptions)
  defp fetch_order!(id), do: read_one!(Order, id, Store.Orders)
  defp fetch_payment_intent!(id), do: read_one!(PaymentIntent, id, Store.Payments)

  defp grants_for(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp count_collections_for_attempt(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp successful_or_current_collection!(attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^attempt_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp count_attempts_for_subscription(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reconcile_handoff(handoff) do
    Facade.reconcile_paid_subscription_renewal_for_system(handoff.order_id,
      renewal_attempt_id: handoff.renewal_attempt_id,
      collection_attempt_id: handoff.collection_attempt_id,
      payment_intent_id: handoff.payment_intent_id
    )
  end

  defp install_status_rejection_trigger!(table, record_id, status) do
    suffix = System.unique_integer([:positive])
    trigger_name = "jc235_reject_#{table}_#{suffix}"
    function_name = "jc235_reject_#{table}_fn_#{suffix}"

    Store.Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.id::text = '#{record_id}' AND NEW.status::text = '#{status}' THEN
        RAISE EXCEPTION 'injected JC-235 #{table} write failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Store.Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF status ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    {trigger_name, function_name}
  end

  defp drop_trigger_and_function!(table, trigger_name, function_name) do
    Store.Repo.query("DROP TRIGGER IF EXISTS #{trigger_name} ON #{table}")
    Store.Repo.query("DROP FUNCTION IF EXISTS #{function_name}()")
    :ok
  end

  defp count_authentication_emails(order_id) do
    EmailOutbox
    |> Ash.Query.filter(
      expr(order_id == ^order_id and template_kind == :payment_authentication_required)
    )
    |> Ash.count!(domain: Store.Comms, authorize?: false, context: %{system?: true})
  end

  defp read_one!(resource, id, domain) do
    resource
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: domain, authorize?: false, context: %{system?: true})
  end
end
