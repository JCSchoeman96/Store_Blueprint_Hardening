defmodule Store.Subscriptions.SuspensionAccessConvergenceTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements.EntitlementGrant
  alias Store.Orders.PaymentApplication
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.{RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)

    previous_payments = Application.get_env(:store, :payments, [])
    enable_stripe!()

    on_exit(fn -> Application.put_env(:store, :payments, previous_payments) end)

    :ok
  end

  test "a grant-write crash rolls back suspension and due processing converges after restart" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_crash", now)
    grant = create_subscription_grant!(fixture, "membership:jc265-crash-main", now)
    assert DateTime.compare(grant.valid_to_at, now) == :gt
    post_count = install_provider_post_counter()
    fail_grant_update!(grant.id)

    assert {:ok, first_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)

    assert {fetch_subscription!(fixture.subscription.id).status,
            Enum.map(source_grants!(fixture.subscription.id), & &1.status)} ==
             {:past_due, [:active]}

    assert first_result == %{due_count: 1, success_count: 0, failed_count: 1}

    assert renewal_attempt_count(fixture.subscription.id) == 0
    assert payment_intent_count(fixture.subscription.id) == 0
    assert :atomics.get(post_count, 1) == 0

    clear_grant_update_failure!()

    assert {:ok, retry_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)
    assert retry_result == %{due_count: 1, success_count: 1, failed_count: 0}

    assert fetch_subscription!(fixture.subscription.id).status == :suspended

    assert [%EntitlementGrant{status: :revoked, revoked_reason: "grace_expired"}] =
             source_grants!(fixture.subscription.id)

    assert :atomics.get(post_count, 1) == 0
    assert renewal_attempt_count(fixture.subscription.id) == 0
    assert payment_intent_count(fixture.subscription.id) == 0

    assert {:ok, replay_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)
    assert replay_result == %{due_count: 0, success_count: 0, failed_count: 0}
    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert [%EntitlementGrant{status: :revoked}] = source_grants!(fixture.subscription.id)
    assert :atomics.get(post_count, 1) == 0
    assert renewal_attempt_count(fixture.subscription.id) == 0
    assert payment_intent_count(fixture.subscription.id) == 0
  end

  test "one required grant mutation failure does not report suspension success" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_single_failure", now)
    grant = create_subscription_grant!(fixture, "membership:jc265-single-failure", now)
    fail_grant_update!(grant.id)

    assert {:ok, result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)

    assert {fetch_subscription!(fixture.subscription.id).status,
            Enum.map(source_grants!(fixture.subscription.id), & &1.status)} ==
             {:past_due, [:active]}

    assert result.success_count == 0
    assert result.failed_count == 1
  end

  test "one failed mutation rolls back every exact-source grant and leaves other sources alone" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    fixture = create_past_due_fixture!("jc265_access_multi_failure", now)

    first_grant = create_subscription_grant!(fixture, "membership:jc265-multi-first", now)

    second_grant =
      create_subscription_grant!(fixture, "membership:jc265-multi-second", now)

    other_fixture = create_other_subscription_fixture!("jc265_other_source", now)

    other_source_grant =
      create_subscription_grant!(other_fixture, "membership:jc265-other-source", now)

    fail_grant_update!(second_grant.id)

    assert {:ok, failed_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)

    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) ==
             [:active, :active]

    assert fetch_subscription!(fixture.subscription.id).status == :past_due
    assert failed_result.success_count == 0
    assert failed_result.failed_count == 1

    assert fetch_grant!(other_source_grant.id).status == :active

    clear_grant_update_failure!()

    assert {:ok, retry_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)
    assert retry_result.success_count == 1
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

    assert {:ok, first_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)
    assert first_result == %{due_count: 1, success_count: 1, failed_count: 0}

    first_suspension = fetch_subscription!(fixture.subscription.id)
    first_grants = source_grants!(fixture.subscription.id)
    first_attempt_count = renewal_attempt_count(fixture.subscription.id)
    first_payment_intent_count = payment_intent_count(fixture.subscription.id)

    assert first_suspension.status == :suspended
    assert Enum.map(first_grants, & &1.status) == [:revoked]

    assert {:ok, replay_result} = SubscriptionsFacade.run_due_renewals_for_system(now: now)
    assert replay_result == %{due_count: 0, success_count: 0, failed_count: 0}

    assert fetch_subscription!(fixture.subscription.id).status == :suspended
    assert Enum.map(source_grants!(fixture.subscription.id), & &1.status) == [:revoked]
    assert renewal_attempt_count(fixture.subscription.id) == first_attempt_count
    assert payment_intent_count(fixture.subscription.id) == first_payment_intent_count
    assert PaymentApplication |> payment_application_count(fixture.subscription.id) == 0
    assert :atomics.get(post_count, 1) == 0
  end

  defp create_past_due_fixture!(prefix, now) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        grace_period_days: 1,
        max_retry_attempts: 0,
        retry_schedule_hours: [0],
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_#{prefix}",
        started_at: DateTime.add(now, -10 * 86_400, :second),
        next_renewal_at: DateTime.add(now, -10, :second)
      })

    past_due_since_at = DateTime.add(now, -2 * 86_400, :second)

    past_due =
      subscription
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: past_due_since_at,
          next_retry_at: nil,
          retry_suppressed_at: nil,
          dunning_attempt_count: 1
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    %{customer: customer, plan: plan, subscription: past_due, now: now}
  end

  defp create_other_subscription_fixture!(prefix, now) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
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
