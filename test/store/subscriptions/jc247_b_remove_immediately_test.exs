defmodule Store.Subscriptions.Jc247BRemoveImmediatelyTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "first payment failure establishes one non-effective effect" do
    fixture = create_due_fixture!("jc247_b_failure")
    stub_payment!("canceled")
    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()
    assert_non_effective!(fixture.subscription.id)
  end

  test "first authentication-required transition establishes one non-effective effect" do
    fixture = create_due_fixture!("jc247_b_auth")
    stub_payment!("requires_action")
    assert {:ok, :processed} = fixture.run.()
    assert_non_effective!(fixture.subscription.id)
  end

  defp stub_payment!(status) do
    StripeAPIStub.stub_payment_intent(fn conn, params ->
      response =
        if status == "requires_action",
          do: %{
            "status" => status,
            "next_action" => %{
              "redirect_to_url" => %{"url" => "https://payments.example.test/authenticate/jc247"}
            }
          },
          else: %{"status" => status}

      StripeAPIStub.json_response(conn, StripeAPIStub.payment_intent_response(params, response))
    end)
  end

  defp create_due_fixture!(label) do
    {:ok, %{rows: [[now]]}} = Repo.query("SELECT clock_timestamp()")
    customer = SubscriptionsFixtures.create_customer!("#{label}_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        retry_schedule_hours: [0, 24, 72],
        max_retry_attempts: 3,
        grace_period_days: 7,
        access_on_past_due: :remove_immediately,
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

  defp assert_non_effective!(subscription_id) do
    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    effects =
      AccessEffect
      |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
      |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert subscription.status == :past_due

    assert [
             %AccessEffect{
               disposition: :non_effective,
               entitlement_kind: nil,
               entitlement_scope_key: nil,
               valid_from_at: nil,
               valid_until_at: nil,
               plan_revision_id: revision_id,
               contract_change_id: change_id
             }
           ] = effects

    assert revision_id == subscription.current_plan_revision_id
    assert change_id == subscription.current_contract_change_id
  end
end
