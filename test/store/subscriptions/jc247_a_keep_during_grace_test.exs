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

  test "nil/nil funded composition produces EFFECTIVE keep-grace target without valid_from_at" do
    fixture = create_due_fixture!("jc247_a_nil_nil", entitlement_pair: {nil, nil})

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.entitlement_kind == nil
    assert effect.valid_from_at == nil
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
  end

  test "effect establishment failure rolls back commercial past_due transition" do
    fixture = create_due_fixture!("jc247_a_effect_rollback")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    before = reload_subscription!(fixture.subscription.id)
    fail_access_effect_insert!(fixture.subscription.id)

    assert {:error, error} =
             Repo.checkout(fn ->
               Repo.query!(
                 "SELECT set_config('store.jc247_fail_access_effect_subscription', $1, true)",
                 [fixture.subscription.id]
               )

               fixture.run.()
             end)

    assert reload_subscription!(fixture.subscription.id).status == before.status
    assert access_effects!(fixture.subscription.id) == []
    assert error.code in ["PAYMENT_FAILED", "INTERNAL_ERROR"]
  end

  test "first authentication-required transition establishes keep-grace effect and preserves outer result" do
    fixture = create_due_fixture!("jc247_a_auth_required")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{"url" => "https://payments.example.test/authenticate/jc247"}
          }
        })
      )
    end)

    assert {:ok, :processed} = fixture.run.()

    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.status == :past_due
    assert subscription.billing_status_reason == "PAYMENT_AUTHENTICATION_REQUIRED"

    [effect] = access_effects!(subscription.id)
    assert effect.disposition == :effective
    assert effect.valid_until_at == subscription.failed_payment_boundary_at
  end

  test "authentication-required replay does not create a second keep-grace producer effect" do
    fixture = create_due_fixture!("jc247_a_auth_replay")
    params_agent = start_supervised!({Agent, fn -> nil end})

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      Agent.update(params_agent, fn _ -> params end)

      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{
          "status" => "requires_action",
          "next_action" => %{
            "redirect_to_url" => %{
              "url" => "https://payments.example.test/authenticate/jc247-replay"
            }
          }
        })
      )
    end)

    assert {:ok, :processed} = fixture.run.()
    subscription = reload_subscription!(fixture.subscription.id)
    [first_effect] = access_effects!(subscription.id)

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
               now: DateTime.add(subscription.failed_payment_boundary_at, -1, :second)
             )

    assert length(access_effects!(subscription.id)) == 1
    assert hd(access_effects!(subscription.id)).id == first_effect.id
  end

  test "malformed keep-grace pair interval rolls back past_due without AccessEffect" do
    fixture = create_due_fixture!("jc247_a_malformed_pair")
    force_malformed_keep_grace_boundary!(fixture.subscription.id)

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    before = reload_subscription!(fixture.subscription.id)

    assert {:error, %{code: "PAYMENT_FAILED"}} =
             Repo.checkout(fn ->
               Repo.query!("SELECT set_config('store.jc247_force_malformed_boundary', '1', true)")

               fixture.run.()
             end)

    assert reload_subscription!(fixture.subscription.id).status == before.status
    assert access_effects!(fixture.subscription.id) == []
  end

  test "postcommit F1 convergence does not change committed payment-failure outer result" do
    fixture = create_due_fixture!("jc247_a_f1_error_outer")

    StripeAPIStub.stub_payment_intent(fn conn, params ->
      StripeAPIStub.json_response(
        conn,
        StripeAPIStub.payment_intent_response(params, %{"status" => "canceled"})
      )
    end)

    assert {:error, %{code: "PAYMENT_FAILED"}} = fixture.run.()
    subscription = reload_subscription!(fixture.subscription.id)
    assert subscription.status == :past_due
    [effect] = access_effects!(subscription.id)

    assert {:ok, :noop} = Facade.execute_effective_access_effect_for_system(effect.id)

    {:ok, %{rows: [[status]]}} =
      Repo.query("SELECT status FROM access_effects WHERE id = $1", [Ecto.UUID.dump!(effect.id)])

    assert status == "applied"
    assert reload_subscription!(subscription.id).status == :past_due
  end

  defp create_due_fixture!(label, opts \\ []) do
    {kind, scope} =
      Keyword.get(opts, :entitlement_pair, {:membership_access, "membership:#{label}"})

    now = db_now!()
    customer = SubscriptionsFixtures.create_customer!(unique_label(label))
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan_attrs = %{
      interval_unit: :day,
      interval_count: 1,
      retry_schedule_hours: [0, 24, 72],
      max_retry_attempts: 3,
      grace_period_days: 7
    }

    plan_attrs =
      if kind == nil and scope == nil do
        Map.merge(plan_attrs, %{entitlement_kind: nil, entitlement_scope_key: nil})
      else
        Map.merge(plan_attrs, %{entitlement_kind: kind, entitlement_scope_key: scope})
      end

    plan = SubscriptionsFixtures.create_subscription_plan!(plan_attrs)

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

  defp force_malformed_keep_grace_boundary!(subscription_id) do
    function_name = "jc247_malformed_boundary_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF current_setting('store.jc247_force_malformed_boundary', true) = '1'
         AND NEW.status::text = 'past_due'
         AND NEW.id::text = current_setting('store.jc247_malformed_boundary_subscription', true) THEN
        NEW.failed_payment_boundary_at := NEW.current_period_start_at;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!("""
    CREATE TRIGGER #{function_name}
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    Repo.query!(
      "SELECT set_config('store.jc247_malformed_boundary_subscription', $1, false)",
      [subscription_id]
    )
  end

  defp fail_access_effect_insert!(subscription_id) do
    function_name = "jc247_fail_access_effect_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      IF NEW.subscription_id::text = current_setting('store.jc247_fail_access_effect_subscription', true)
         OR NEW.subscription_id::text = current_setting('store.jc247_fail_access_effect_subscription', false) THEN
        RAISE EXCEPTION 'injected JC-247 AccessEffect insert failure';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    Repo.query!(
      "SELECT set_config('store.jc247_fail_access_effect_subscription', $1, false)",
      [subscription_id]
    )

    Repo.query!("""
    CREATE TRIGGER #{function_name}
    BEFORE INSERT ON access_effects
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)
  end
end
