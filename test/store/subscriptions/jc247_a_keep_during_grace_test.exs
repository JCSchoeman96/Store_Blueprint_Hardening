defmodule Store.Subscriptions.Jc247AKeepDuringGraceTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.Subscription
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "first bound payment failure establishes keep-grace EFFECTIVE target at grace boundary" do
    fixture = create_due_fixture!("jc247_a_first_failure")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    attempt = fetch_attempt!(subscription.id)

    assert subscription.status == :past_due
    assert subscription.current_dunning_renewal_attempt_id == attempt.id
    assert %DateTime{} = subscription.failed_payment_boundary_at

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.entitlement_kind == :membership_access
    assert effect.valid_from_at == subscription.current_period_start_at
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
    assert effect.plan_revision_id == subscription.current_plan_revision_id
    assert effect.contract_change_id == subscription.current_contract_change_id
  end

  test "past_due retry failure does not establish a second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247_a_retry_no_second_effect")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    [first_effect] = access_effects!(subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: subscription.next_retry_at
             )

    subscription = reload_subscription!(subscription.id)
    effects = access_effects!(subscription.id)
    assert length(effects) == 1
    assert hd(effects).id == first_effect.id
    assert subscription.aggregate_version > first_effect.source_version
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
      run: fn -> Facade.process_due_subscription_renewal_for_system(subscription.id, now: now) end
    }
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
