defmodule Store.Subscriptions.Sbh3004FailedPaymentSuspensionBoundaryTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info
  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures

  test "Subscription stores an internal nullable failed-payment boundary" do
    assert attribute = Info.attribute(Subscription, :failed_payment_boundary_at)
    assert attribute.type == Ash.Type.UtcDatetimeUsec
    assert attribute.allow_nil?
    refute attribute.public?
  end

  test "database rejects an active Subscription with a failed-payment boundary" do
    customer = SubscriptionsFixtures.create_customer!("jc239_active_boundary")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    boundary_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE subscriptions SET failed_payment_boundary_at = $2 WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id), boundary_at]
             )
  end

  test "ordinary renewal selection excludes PAST_DUE rows without a trusted boundary" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    subscription = create_subscription!("jc239_missing_boundary_due")

    Repo.query!(
      "UPDATE subscriptions SET status = 'past_due', next_retry_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id), DateTime.add(now, -1, :second)]
    )

    due_ids =
      Subscription
      |> Ash.Query.for_read(:read_due_for_system, %{now: now, limit: 100})
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    refute subscription.id in due_ids
  end

  test "independent boundary selection finds retry-suppressed PAST_DUE rows" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    subscription = create_subscription!("jc239_suppressed_boundary_due")

    Repo.query!(
      """
      UPDATE subscriptions
      SET status = 'past_due',
          failed_payment_boundary_at = $2,
          retry_suppressed_at = $3,
          next_retry_at = NULL
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(subscription.id),
        DateTime.add(now, -1, :second),
        DateTime.add(now, -2, :second)
      ]
    )

    due_ids =
      Subscription
      |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{
        now: now,
        limit: 100
      })
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
      |> Enum.map(& &1.id)

    assert subscription.id in due_ids
  end

  test "boundary discovery advances through a stable bounded keyset" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    subscriptions = Enum.map(1..3, &create_subscription!("jc239_boundary_page_#{&1}"))
    boundary_at = DateTime.add(now, -1, :second)

    Enum.each(subscriptions, fn subscription ->
      Repo.query!(
        "UPDATE subscriptions SET status = 'past_due', failed_payment_boundary_at = $2 WHERE id = $1",
        [Ecto.UUID.dump!(subscription.id), boundary_at]
      )
    end)

    assert {:ok, first_page} =
             Subscription
             |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{
               now: now,
               limit: 2
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(first_page) == 2
    [last_first_page | _] = Enum.reverse(first_page)

    assert {:ok, second_page} =
             Subscription
             |> Ash.Query.for_read(:read_due_failed_payment_boundary_for_system, %{
               now: now,
               after_boundary_at: last_first_page.failed_payment_boundary_at,
               after_id: last_first_page.id,
               limit: 2
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(second_page) == 1
    refute Enum.any?(second_page, &(&1.id in Enum.map(first_page, fn item -> item.id end)))
  end

  test "missing-boundary reconciliation advances by id without loading the full quarantine set" do
    subscriptions = Enum.map(1..3, &create_subscription!("jc239_missing_page_#{&1}"))

    Enum.each(subscriptions, fn subscription ->
      Repo.query!("UPDATE subscriptions SET status = 'past_due' WHERE id = $1", [
        Ecto.UUID.dump!(subscription.id)
      ])
    end)

    assert {:ok, first_page} =
             Subscription
             |> Ash.Query.for_read(:read_past_due_missing_boundary_for_system, %{
               after_id: nil,
               limit: 2
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(first_page) == 2
    last_id = first_page |> List.last() |> Map.fetch!(:id)

    assert {:ok, second_page} =
             Subscription
             |> Ash.Query.for_read(:read_past_due_missing_boundary_for_system, %{
               after_id: last_id,
               limit: 2
             })
             |> Ash.read(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert length(second_page) == 1
    assert hd(second_page).id not in Enum.map(first_page, & &1.id)
  end

  test "due boundary suspends and establishes a required non-effective AccessEffect atomically" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("jc239_boundary_suspend")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:jc239-boundary-suspend"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now, limit: 100)
    past_due = fetch_subscription!(subscription.id)
    assert past_due.status == :past_due

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    assert {:ok, %{due_count: 1, suspended_count: 1, failed_count: 0}} =
             Facade.run_due_failed_payment_suspensions_for_system(limit: 100)

    suspended = fetch_subscription!(subscription.id)
    assert suspended.status == :suspended

    assert %{rows: [[effect_id, "required", "non_effective", effect_version]]} =
             Repo.query!(
               "SELECT id::text, status, disposition, source_version FROM access_effects WHERE subscription_id = $1",
               [Ecto.UUID.dump!(subscription.id)]
             )

    assert effect_version == suspended.aggregate_version

    assert {:ok, :applied} = Facade.execute_suspension_access_effect_for_system(effect_id)

    assert %{rows: [["applied", [], delivered_at]]} =
             Repo.query!(
               "SELECT status, projection_user_ids, projection_delivered_at FROM access_effects WHERE id = $1",
               [Ecto.UUID.dump!(effect_id)]
             )

    refute is_nil(delivered_at)
  end

  test "failure to create the required AccessEffect rolls back suspension" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    customer = SubscriptionsFixtures.create_customer!("jc239_effect_rollback")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!(%{max_retry_attempts: 0})
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, %{failed_count: 1}} = Facade.run_due_renewals_for_system(now: now)

    Repo.query!(
      "UPDATE subscriptions SET failed_payment_boundary_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    fail_access_effect_insert!(subscription.id)

    assert {:ok, result} = Facade.run_due_failed_payment_suspensions_for_system(limit: 100)
    assert result.due_count == 1
    assert result.suspended_count == 0
    assert result.failed_count == 1
    assert fetch_subscription!(subscription.id).status == :past_due

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM access_effects WHERE subscription_id = $1",
               [Ecto.UUID.dump!(subscription.id)]
             )
  end

  test "boundary and quarantine selectors use their partial indexes" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    assert {:ok, %{rows: boundary_plan}} =
             Repo.query(
               "EXPLAIN SELECT id FROM subscriptions WHERE status = 'past_due' AND failed_payment_boundary_at IS NOT NULL AND failed_payment_boundary_at <= clock_timestamp() ORDER BY failed_payment_boundary_at, id LIMIT 100"
             )

    boundary_plan = boundary_plan |> List.flatten() |> Enum.join(" ")
    assert boundary_plan =~ "subscriptions_failed_payment_boundary_due_index"
    assert boundary_plan =~ "Limit"

    assert {:ok, %{rows: quarantine_plan}} =
             Repo.query(
               "EXPLAIN SELECT id FROM subscriptions WHERE status = 'past_due' AND failed_payment_boundary_at IS NULL AND id > '00000000-0000-7000-8000-000000000000'::uuid ORDER BY id LIMIT 100"
             )

    quarantine_plan = quarantine_plan |> List.flatten() |> Enum.join(" ")
    assert quarantine_plan =~ "subscriptions_past_due_missing_boundary_index"
    assert quarantine_plan =~ "Limit"
  end

  defp create_subscription!(prefix) do
    customer =
      SubscriptionsFixtures.create_customer!("#{prefix}_#{System.unique_integer([:positive])}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    subscription
  end

  defp fetch_subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fail_access_effect_insert!(subscription_id) do
    function_name = "jc239_fail_access_effect_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = current_setting('store.jc239_fail_access_effect_subscription', true) THEN
        RAISE EXCEPTION 'injected JC-239 AccessEffect insert failure';
      END IF;

      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{function_name}
    BEFORE INSERT ON access_effects
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    Repo.query!(
      "SELECT set_config('store.jc239_fail_access_effect_subscription', $1, true)",
      [subscription_id]
    )
  end
end
