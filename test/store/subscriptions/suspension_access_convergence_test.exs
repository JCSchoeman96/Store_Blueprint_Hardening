defmodule Store.Subscriptions.SuspensionAccessConvergenceTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.Cache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.PaymentApplication
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, RenewalAttempt, Subscription}
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)

    previous_payments = Application.get_env(:store, :payments, [])
    enable_stripe!()

    on_exit(fn -> Application.put_env(:store, :payments, previous_payments) end)

    :ok
  end

  test "a failed source revoke remains recoverable after suspension commits" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_crash", now)
    grant = create_subscription_grant!(fixture, "membership:jc265-crash-main", now)
    assert DateTime.compare(grant.valid_to_at, now) == :gt
    post_count = install_provider_post_counter()

    assert {:ok, suspension_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert suspension_result.suspended_count == 1
    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    effect = current_effect!(fixture.subscription.id)
    assert effect.status == :required

    fail_grant_update!(grant.id)

    assert {:error, _reason} =
             SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)

    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) == [:active]
    assert fetch_effect!(effect.id).status == :failed_retryable
    recovery_cursor_start = DateTime.add(fetch_effect!(effect.id).updated_at, -1, :microsecond)
    assert payment_intent_count(fixture.subscription.id) == 0
    assert :atomics.get(post_count, 1) == 0

    clear_grant_update_failure!()

    assert {:ok, retry_result} =
             SubscriptionsFacade.run_subscription_access_effect_recovery_for_system(
               limit: 100,
               execution_after_updated_at: recovery_cursor_start,
               execution_after_id: "00000000-0000-0000-0000-000000000000",
               skip_projection: true,
               skip_effective_execution: true
             )

    assert retry_result.execution_count == 1
    assert retry_result.failed_count == 0

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
             source_grants!(fixture.subscription.id)

    assert :atomics.get(post_count, 1) == 0
    assert renewal_attempt_count(fixture.subscription.id) == 1
    assert payment_intent_count(fixture.subscription.id) == 0

    assert {:ok, replay_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert replay_result.due_count == 0
    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert [%EntitlementGrant{status: :revoked}] = source_grants!(fixture.subscription.id)
    assert :atomics.get(post_count, 1) == 0
    assert renewal_attempt_count(fixture.subscription.id) == 1
    assert payment_intent_count(fixture.subscription.id) == 0
  end

  test "one required grant mutation failure does not report suspension success" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_single_failure", now)
    grant = create_subscription_grant!(fixture, "membership:jc265-single-failure", now)

    assert {:ok, suspension_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert suspension_result.suspended_count == 1
    effect = current_effect!(fixture.subscription.id)
    fail_grant_update!(grant.id)

    assert {:error, _reason} =
             SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)

    assert {fetch_subscription!(fixture.subscription.id).status,
            Enum.map(source_grants!(fixture.subscription.id), & &1.status)} ==
             {:suspended, [:active]}

    assert fetch_effect!(effect.id).status == :failed_retryable
  end

  test "one failed mutation rolls back every exact-source grant and leaves other sources alone" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_multi_failure", now)

    first_grant = create_subscription_grant!(fixture, "membership:jc265-multi-first", now)

    second_grant =
      create_subscription_grant!(fixture, "membership:jc265-multi-second", now)

    other_fixture =
      create_other_subscription_fixture!(
        "jc265_other_source",
        now,
        fixture.customer.id
      )

    other_source_grant =
      create_subscription_grant!(other_fixture, "membership:jc265-other-source", now)

    assert {:ok, suspension_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert suspension_result.suspended_count == 1
    effect = current_effect!(fixture.subscription.id)
    fail_grant_update!(second_grant.id)

    assert {:error, _reason} =
             SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)

    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) ==
             [:active, :active]

    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert fetch_effect!(effect.id).status == :failed_retryable

    assert fetch_grant!(other_source_grant.id).status == :active

    clear_grant_update_failure!()

    assert {:ok, retry_result} =
             SubscriptionsFacade.run_subscription_access_effect_recovery_for_system(
               limit: 100,
               execution_after_updated_at:
                 DateTime.add(fetch_effect!(effect.id).updated_at, -1, :microsecond),
               execution_after_id: "00000000-0000-0000-0000-000000000000",
               skip_projection: true,
               skip_effective_execution: true
             )

    assert retry_result.execution_count == 1
    assert retry_result.failed_count == 0
    assert fetch_subscription!(fixture.subscription.id).status == :suspended

    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) ==
             [:revoked, :revoked]

    assert fetch_grant!(other_source_grant.id).status == :active
    assert fetch_grant!(first_grant.id).revoked_reason == "grace_expired"
    assert fetch_grant!(second_grant.id).revoked_reason == "grace_expired"
  end

  test "replaying a completed suspension has no additional access or payment effects" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_replay", now)
    create_subscription_grant!(fixture, "membership:jc265-replay", now)
    post_count = install_provider_post_counter()

    assert {:ok, suspension_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert suspension_result.suspended_count == 1
    effect = current_effect!(fixture.subscription.id)

    assert {:ok, :applied} =
             SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)

    first_suspension = fetch_subscription!(fixture.subscription.id)
    first_grants = source_grants!(fixture.subscription.id)
    first_attempt_count = renewal_attempt_count(fixture.subscription.id)
    first_payment_intent_count = payment_intent_count(fixture.subscription.id)

    assert first_suspension.status == :suspended
    assert Enum.map(first_grants, & &1.status) == [:revoked]

    assert {:ok, replay_result} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    assert replay_result.due_count == 0

    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) == [:revoked]
    assert renewal_attempt_count(fixture.subscription.id) == first_attempt_count
    assert payment_intent_count(fixture.subscription.id) == first_payment_intent_count
    assert PaymentApplication |> payment_application_count(fixture.subscription.id) == 0
    assert :atomics.get(post_count, 1) == 0
  end

  test "projection repair retries after APPLIED without changing grant truth" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc239_projection_crash", now)
    create_subscription_grant!(fixture, "membership:jc239-projection", now)

    assert {:ok, %{suspended_count: 1}} =
             SubscriptionsFacade.run_due_failed_payment_suspensions_for_system()

    effect = current_effect!(fixture.subscription.id)

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(fixture.customer.id))

    assert :ok = Supervisor.terminate_child(Store.Supervisor, Cache)

    try do
      assert {:ok, :applied_projection_pending} =
               SubscriptionsFacade.execute_suspension_access_effect_for_system(effect.id)
    after
      assert {:ok, _pid} = Supervisor.restart_child(Store.Supervisor, Cache)
    end

    applied = fetch_effect!(effect.id)
    assert applied.status == :applied
    assert applied.projection_user_ids == [fixture.customer.id]
    assert is_nil(applied.projection_delivered_at)
    [revoked_before] = source_grants!(fixture.subscription.id)
    assert revoked_before.status == :revoked

    Repo.query!(
      "UPDATE subscriptions SET status = 'canceled', canceled_reason = 'user_request', current_dunning_renewal_attempt_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(fixture.subscription.id)]
    )

    assert :ok =
             SubscriptionsFacade.repair_suspension_access_effect_projection_for_system(effect.id)

    assert_receive {:entitlements_invalidated, user_id, "non_effective_access_effect_applied",
                    _at}

    assert user_id == fixture.customer.id

    repaired = fetch_effect!(effect.id)
    assert repaired.status == :applied
    assert %DateTime{} = repaired.projection_delivered_at
    assert [revoked_after] = source_grants!(fixture.subscription.id)
    assert revoked_after.status == :revoked
    assert revoked_after.updated_at == revoked_before.updated_at
  end

  defp create_past_due_fixture!(prefix, now) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        grace_period_days: 1,
        max_retry_attempts: 0,
        retry_schedule_hours: [0],
        access_on_past_due: :remove_immediately,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -10 * 86_400, :second),
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    assert {:ok, %{due_count: 1, failed_count: 1}} =
             SubscriptionsFacade.run_due_renewals_for_system(now: now)

    past_due = fetch_subscription!(subscription.id)
    assert past_due.status == :past_due
    assert %DateTime{} = past_due.failed_payment_boundary_at

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), DateTime.add(now, -1, :second)]
    )

    %{customer: customer, plan: plan, subscription: past_due, now: now}
  end

  defp create_other_subscription_fixture!(prefix, now, existing_customer_id) do
    customer =
      if is_binary(existing_customer_id) do
        %{id: existing_customer_id}
      else
        SubscriptionsFixtures.create_customer!(prefix)
      end

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: now,
        next_renewal_at: DateTime.add(now, 86_400, :second)
      })

    %{customer: customer, subscription: subscription}
  end

  defp create_subscription_grant!(fixture, scope_key, now, source_id \\ nil) do
    EntitlementGrant
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: fixture.customer.id,
        kind: :membership_access,
        scope_key: scope_key,
        source_kind: :subscription,
        source_id: source_id || fixture.subscription.id,
        status: :active,
        valid_from_at: DateTime.add(now, -60, :second),
        valid_to_at: DateTime.add(now, 86_400, :second)
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fail_grant_update!(grant_id) do
    unique = System.unique_integer([:positive])
    function_name = "jc265_fail_entitlement_grant_#{unique}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.id::text = current_setting('store.jc265_fail_grant_id', true) THEN
        RAISE EXCEPTION 'injected JC-265 entitlement grant update failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{function_name}
    BEFORE UPDATE ON entitlement_grants
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    Repo.query!(
      "SELECT set_config('store.jc265_fail_grant_id', $1, true)",
      [grant_id]
    )
  end

  defp clear_grant_update_failure! do
    Repo.query!("SELECT set_config('store.jc265_fail_grant_id', '', true)")
  end

  defp source_grants!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_grant!(grant_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(id == ^grant_id))
    |> Ash.read_one!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp current_effect!(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(
      expr(subscription_id == ^subscription_id and disposition == :non_effective)
    )
    |> Ash.Query.sort(source_version: :desc)
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_effect!(effect_id) do
    AccessEffect
    |> Ash.Query.filter(expr(id == ^effect_id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp renewal_attempt_count(subscription_id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp payment_intent_count(subscription_id) do
    PaymentIntent
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.count!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end

  defp payment_application_count(PaymentApplication, subscription_id) do
    order_ids =
      RenewalAttempt
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.Query.select([:order_id])
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.order_id)

    PaymentApplication
    |> Ash.Query.filter(expr(order_id in ^order_ids))
    |> Ash.count!(domain: Store.Orders, authorize?: false, context: %{system?: true})
  end

  defp install_provider_post_counter do
    post_count = :atomics.new(1, [])

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      :atomics.add(post_count, 1, 1)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "processing"})
      )
    end)

    post_count
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
