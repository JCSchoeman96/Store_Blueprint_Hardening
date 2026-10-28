defmodule Store.Subscriptions.Jc247AAcceptanceMatrixTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.Inputs.QueueSubscriptionPlanChangeInput
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  @cursor_floor "00000000-0000-7000-8000-000000000000"
  @barrier_timeout 10_000

  setup context do
    StripeAPIStub.setup_default(context)
    {:ok, context: context}
  end

  test "TASK1 payment failure postcommit barrier sees exact effect id before F1", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247mx_exact_id")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    stub_canceled_payment!()

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             run_failure_with_barrier!(context, fixture, barrier, fn _effect -> :ok end)

    [effect] = access_effects!(fixture.subscription.id)
    assert effect.status == :applied
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 applied", %{context: context} do
    assert_payment_failure_outer_preserved(context, fn _effect -> :ok end)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 projection pending", %{
    context: context
  } do
    constraint = add_projection_pending_constraint!()

    assert_payment_failure_outer_preserved(context, fn _effect -> :ok end, constraint: constraint)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 superseded", %{context: context} do
    assert_payment_failure_outer_preserved(context, fn effect ->
      subscription = reload_subscription!(effect.subscription_id)
      attempt = fetch_attempt!(subscription.id)
      establish_newer_non_effective_effect!(subscription, attempt)
    end)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 noop", %{context: context} do
    assert_payment_failure_outer_preserved(context, &mark_effect_applied!/1)
  end

  test "TASK1 payment failure preserves PAYMENT_FAILED for F1 error", %{context: context} do
    assert_payment_failure_outer_preserved(context, fn _effect -> :ok end, grant_block: true)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 applied", %{context: context} do
    assert_auth_outer_preserved(context, fn _effect -> :ok end)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 noop", %{context: context} do
    assert_auth_outer_preserved(context, &mark_effect_applied!/1)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 projection pending", %{
    context: context
  } do
    constraint = add_projection_pending_constraint!()
    assert_auth_outer_preserved(context, fn _effect -> :ok end, constraint: constraint)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 superseded", %{context: context} do
    assert_auth_outer_preserved(context, fn effect ->
      subscription = reload_subscription!(effect.subscription_id)
      attempt = fetch_attempt!(subscription.id)
      establish_newer_non_effective_effect!(subscription, attempt)
    end)
  end

  test "TASK1 auth required preserves {:ok, :processed} for F1 error", %{context: context} do
    assert_auth_outer_preserved(context, fn _effect -> :ok end, grant_block: true)
  end

  test "TASK1 auth replay matrix — no second producer effect" do
    fixture = create_due_fixture!("jc247mx_auth_replay_matrix")
    {:ok, params_agent} = Agent.start_link(fn -> nil end)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      Agent.update(params_agent, fn _ -> params end)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{
              "url" => "https://payments.example.test/matrix-replay"
            }
          }
        })
      )
    end)

    assert {:ok, :processed} = fixture.run.()
    [first] = access_effects!(fixture.subscription.id)

    StripeAPIStub.stub_observation(fn conn ->
      params = Agent.get(params_agent, & &1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "requires_action"})
      )
    end)

    assert {:ok, :processed} =
             Facade.process_due_subscription_renewal_for_system(
               fixture.subscription.id,
               now: reload_subscription!(fixture.subscription.id).failed_payment_boundary_at
             )

    assert [^first] = access_effects!(fixture.subscription.id)
    Agent.stop(params_agent)
  end

  test "TASK4 contract change X to Y reconciliation repairs provenance only" do
    fixture = create_due_fixture!("jc247mx_xy")
    stub_canceled_payment!()

    case fixture.run.() do
      {:error, %{code: "PAYMENT_FAILED"}} -> :ok
      other -> flunk("STOP=establishment rejects: #{inspect(other)}")
    end

    subscription = reload_subscription!(fixture.subscription.id)
    [e1] = access_effects!(subscription.id)
    attempt = fetch_attempt!(subscription.id)
    pointer = subscription.current_dunning_renewal_attempt_id
    boundary = subscription.failed_payment_boundary_at
    funded_revision_id = subscription.current_plan_revision_id

    assert attempt.charged_contract_snapshot["access_on_past_due"] == "keep_during_grace"
    assert e1.plan_revision_id == funded_revision_id

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :month,
        interval_count: 1,
        grace_period_days: 7,
        max_retry_attempts: 3,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc247mx-target"
      })

    SubscriptionsFixtures.create_plan_revision!(target_plan)
    SubscriptionsFixtures.attach_variant_plan!(subscription.variant_id, target_plan.id)

    assert {:ok, queued_y} = queue_plan_change(fixture.customer, subscription.id, target_plan)
    change_y = fetch_contract_change!(queued_y.current_contract_change_id)
    subscription = reload_subscription!(subscription.id)
    assert subscription.current_contract_change_id == change_y.id

    if e1.contract_change_id == change_y.id do
      Repo.query!(
        "UPDATE access_effects SET contract_change_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(e1.id)]
      )
    end

    Repo.query!(
      "UPDATE access_effects SET valid_from_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(e1.id), ~U[2020-01-01 00:00:00.000000Z]]
    )

    Repo.query!(
      """
      UPDATE access_effects
      SET status = 'required',
          contract_change_id = NULL,
          projection_delivered_at = NULL,
          projection_user_ids = NULL
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(e1.id)]
    )

    set_updated_at!([fetch_effect!(e1.id)], ~U[2026-10-23 11:00:00.000000Z])
    e1 = fetch_effect!(e1.id)

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: e1.inserted_at,
               after_inserted_at: e1.inserted_at,
               after_id: @cursor_floor
             )

    assert result.repaired_count == 1
    rows = access_effect_rows!(subscription.id)
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.status == "superseded" and &1.id == e1.id))

    e2 = Enum.find(rows, &(&1.status == "required" and &1.id != e1.id))
    assert e2.contract_change_id == change_y.id
    assert e2.plan_revision_id == funded_revision_id
    assert reload_subscription!(subscription.id).current_dunning_renewal_attempt_id == pointer
    assert reload_subscription!(subscription.id).failed_payment_boundary_at == boundary
  end

  test "TASK5 F1 V1 succeeds after aggregate advances to V2" do
    fixture = create_due_fixture!("jc247mx_v1_after_v2")
    stub_canceled_payment!()
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    [effect] = access_effects!(subscription.id)
    v1 = effect.source_version
    bump_aggregate_version!(subscription.id)
    assert reload_subscription!(subscription.id).aggregate_version > v1

    assert {:ok, outcome} = Facade.execute_effective_access_effect_for_system(effect.id)
    assert outcome in [:applied, :noop]
    assert fetch_effect!(effect.id).status == :applied
  end

  test "TASK5 exact failure replay does not create second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247mx_exact_replay")
    stub_canceled_payment!()
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    [first] = access_effects!(subscription.id)
    pointer = subscription.current_dunning_renewal_attempt_id
    boundary = subscription.failed_payment_boundary_at
    bump_aggregate_version!(subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(
               subscription.id,
               now: subscription.next_retry_at
             )

    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.current_dunning_renewal_attempt_id == pointer
    assert subscription.failed_payment_boundary_at == boundary
    assert [^first] = access_effects!(subscription.id)
    assert {:ok, outcome} = Facade.execute_effective_access_effect_for_system(first.id)
    assert outcome in [:applied, :noop]
    assert fetch_effect!(first.id).status == :applied
  end

  @tag :real_connections
  test "TASK6 paused keep-grace sync loses to cancel-now non_effective effect", %{
    context: context
  } do
    fixture = create_due_fixture!("jc247mx_race_cancel")
    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    stub_canceled_payment!()

    failure_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [keep_grace] = access_effects!(subscription_id)

    cancel_task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())

        Facade.cancel_subscription_for_user(
          fixture.customer,
          subscription_id,
          :now
        )
      end)

    assert {:ok, %Subscription{status: :canceled}} = Task.await(cancel_task, @barrier_timeout)
    send(failure_task.pid, {:jc247_release_keep_grace_sync, barrier})
    assert {:error, %{code: "PAYMENT_FAILED"}} = Task.await(failure_task, @barrier_timeout)

    effects = access_effects!(subscription_id)
    keep = fetch_effect!(keep_grace.id)
    assert keep.status in [:superseded, :applied, :required]
    assert Enum.any?(effects, &(&1.disposition == :non_effective))
  end

  test "TASK7 unrelated subscription grant unchanged after keep-grace F1" do
    fixture = create_due_fixture!("jc247mx_isolation")
    subscription = reload_subscription!(fixture.subscription.id)

    %{variant: other_variant} = SubscriptionsFixtures.create_subscription_sellable!()

    other_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "other-sub-grant"
      })

    SubscriptionsFixtures.attach_variant_plan!(other_variant.id, other_plan.id)

    other =
      SubscriptionsFixtures.create_subscription_fixture!(
        fixture.customer.id,
        other_variant,
        other_plan,
        %{provider_billing_ref: "pm_jc247mx_other"}
      )

    unrelated =
      EntitlementGrant
      |> Ash.Changeset.for_create(
        :issue,
        %{
          user_id: subscription.user_id,
          kind: :membership_access,
          scope_key: "other-subscription-grant",
          source_kind: :subscription,
          source_id: other.subscription.id,
          status: :active,
          valid_from_at: ~U[2020-01-01 00:00:00.000000Z],
          valid_to_at: ~U[2030-01-01 00:00:00.000000Z]
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})

    stub_canceled_payment!()
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    before = snapshot_grant!(unrelated.id)
    assert length(access_effects!(subscription.id)) == 1
    assert snapshot_grant!(unrelated.id) == before
  end

  defp assert_payment_failure_outer_preserved(context, at_barrier_fn, opts \\ []) do
    fixture = create_due_fixture!("jc247mx_pf_#{System.unique_integer([:positive])}")

    if Keyword.get(opts, :grant_block) do
      constraint = add_grant_block_constraint!(fixture.subscription.id)

      on_exit(fn ->
        Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    if constraint = Keyword.get(opts, :constraint) do
      on_exit(fn ->
        Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    stub_canceled_payment!()

    outer =
      run_failure_with_barrier!(context, fixture, barrier, fn effect ->
        refute Repo.in_transaction?()
        assert effect.status == :required
        at_barrier_fn.(effect)
      end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = outer
    assert reload_subscription!(fixture.subscription.id).status == :past_due
  end

  defp assert_auth_outer_preserved(context, at_barrier_fn, opts \\ []) do
    fixture = create_due_fixture!("jc247mx_auth_#{System.unique_integer([:positive])}")

    if Keyword.get(opts, :grant_block) do
      constraint = add_grant_block_constraint!(fixture.subscription.id)

      on_exit(fn ->
        Repo.query!("ALTER TABLE entitlement_grants DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    if constraint = Keyword.get(opts, :constraint) do
      on_exit(fn ->
        Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
      end)
    end

    barrier = make_ref()
    handler_id = attach_dunning_postcommit_barrier!(self(), barrier, fixture.subscription.id)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    stub_requires_action_payment!("auth-#{System.unique_integer([:positive])}")

    outer =
      run_auth_with_barrier!(context, fixture, barrier, fn effect ->
        at_barrier_fn.(effect)
      end)

    assert {:ok, :processed} = outer
    assert reload_subscription!(fixture.subscription.id).status == :past_due
  end

  defp run_failure_with_barrier!(context, fixture, barrier, at_barrier_fn) do
    task =
      Task.async(fn ->
        Sandbox.allow(Store.Repo, context.sandbox_owners[Store.Repo], self())
        Sandbox.allow(Store.DirectRepo, context.sandbox_owners[Store.DirectRepo], self())
        fixture.run.()
      end)

    assert_receive {:jc247_postcommit_dunning, ^barrier, subscription_id}, @barrier_timeout
    [effect] = access_effects!(subscription_id)
    at_barrier_fn.(effect)
    send(task.pid, {:jc247_release_keep_grace_sync, barrier})
    Task.await(task, @barrier_timeout)
  end

  defp run_auth_with_barrier!(context, fixture, barrier, at_barrier_fn) do
    run_failure_with_barrier!(context, fixture, barrier, at_barrier_fn)
  end

  defp attach_dunning_postcommit_barrier!(owner, barrier_ref, subscription_id) do
    handler_id = "jc247_dunning_barrier_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:store, :subscriptions, :dunning],
        fn _event, _measurements, %{subscription_id: sub_id}, config ->
          if sub_id == config.subscription_id do
            send(config.owner, {:jc247_postcommit_dunning, config.barrier_ref, sub_id})

            receive do
              {:jc247_release_keep_grace_sync, ref} when ref == config.barrier_ref -> :ok
            after
              @barrier_timeout -> raise "JC247 keep-grace sync barrier timed out"
            end
          end
        end,
        %{owner: owner, barrier_ref: barrier_ref, subscription_id: subscription_id}
      )

    handler_id
  end

  defp add_projection_pending_constraint! do
    constraint = "jc247mx_proj_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE access_effects
    ADD CONSTRAINT #{constraint}
    CHECK (projection_delivered_at IS NULL)
    NOT VALID
    """)

    on_exit(fn ->
      Repo.query!("ALTER TABLE access_effects DROP CONSTRAINT IF EXISTS #{constraint}")
    end)

    constraint
  end

  defp add_grant_block_constraint!(subscription_id) do
    constraint = "jc247mx_grant_#{System.unique_integer([:positive])}"

    Repo.query!("""
    ALTER TABLE entitlement_grants
    ADD CONSTRAINT #{constraint}
    CHECK (source_id <> '#{subscription_id}'::uuid OR status <> 'active')
    NOT VALID
    """)

    constraint
  end

  defp mark_effect_applied!(effect) do
    Repo.query!(
      "UPDATE access_effects SET status = 'applied' WHERE id = $1",
      [Ecto.UUID.dump!(effect.id)]
    )
  end

  defp stub_canceled_payment! do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)
  end

  defp stub_requires_action_payment!(slug) do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{"url" => "https://payments.example.test/#{slug}"}
          }
        })
      )
    end)
  end

  defp queue_plan_change(customer, subscription_id, plan) do
    assert {:ok, input} =
             QueueSubscriptionPlanChangeInput.new(%{
               subscription_id: subscription_id,
               subscription_plan_id: plan.id
             })

    Facade.queue_subscription_plan_change_for_user(customer, subscription_id, input)
  end

  defp establish_newer_non_effective_effect!(subscription, attempt) do
    {:ok, %{rows: [[source_version]]}} =
      Repo.query(
        "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1 RETURNING aggregate_version",
        [Ecto.UUID.dump!(subscription.id)]
      )

    current = reload_subscription!(subscription.id)

    attrs = %{
      subscription_id: current.id,
      source_version: source_version,
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: current.source_order_line_item_id,
      contract_change_id: current.current_contract_change_id,
      plan_revision_id: attempt.plan_revision_id
    }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, _effect} = Facade.establish_access_effect_for_system(input)
  end

  defp create_due_fixture!(label) do
    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{label}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{label}",
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    %{
      subscription: subscription,
      customer: customer,
      run: fn -> Facade.process_due_subscription_renewal_for_system(subscription.id, now: now) end
    }
  end

  defp fetch_contract_change!(id) do
    ContractChange
    |> Ash.get!(id, domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp snapshot_grant!(grant_id) do
    {:ok, %{rows: [row]}} =
      Repo.query(
        "SELECT status, valid_from_at, valid_to_at, revoked_at, revoked_reason FROM entitlement_grants WHERE id = $1",
        [Ecto.UUID.dump!(grant_id)]
      )

    row
  end

  defp fetch_effect!(id) do
    AccessEffect
    |> Ash.get!(id, domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effect_rows!(subscription_id) do
    {:ok, result} =
      Repo.query(
        """
        SELECT id::text, status, contract_change_id::text, plan_revision_id::text
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version ASC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    result.rows
    |> Enum.map(fn [id, status, contract_change_id, plan_revision_id] ->
      %{
        id: id,
        status: status,
        contract_change_id: contract_change_id,
        plan_revision_id: plan_revision_id
      }
    end)
  end

  defp set_updated_at!(effects, updated_at) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        updated_at
      ])
    end)
  end

  defp bump_aggregate_version!(subscription_id) do
    Repo.query!(
      "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
      [Ecto.UUID.dump!(subscription_id)]
    )
  end

  defp unique_label(label), do: "#{label}_#{Ecto.UUID.generate()}"

  defp db_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp reload_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_attempt!(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp access_effects!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.Query.sort(source_version: :asc)
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end
end
