defmodule Store.Subscriptions.AccessEffectTargetOrderReconciliationTest do
  use Store.DataCase, async: false

  require Ash.Query
  import Ash.Expr

  alias Store.Repo
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.Facade
  alias Store.Subscriptions.Inputs.EstablishAccessEffectInput
  alias Store.Subscriptions.RenewalAttempt
  alias Store.SubscriptionsFixtures

  @cursor_floor "00000000-0000-7000-8000-000000000000"

  test "candidate selector and partial index use the immutable key and unresolved statuses" do
    query =
      AccessEffect
      |> Ash.Query.for_read(:read_target_order_candidates_for_system, %{
        through_inserted_at: ~U[2026-10-23 12:00:00.000000Z],
        after_inserted_at: nil,
        after_id: nil,
        limit: 500
      })

    assert query.sort == [inserted_at: :asc, id: :asc]
    assert query.limit == 500
    refute inspect(query.filter) =~ "disposition"

    %{rows: [[valid?, ready?, key_columns, predicate]]} =
      Repo.query!("""
      SELECT index_state.indisvalid,
             index_state.indisready,
             ARRAY(
               SELECT attribute.attname
               FROM unnest(index_state.indkey) WITH ORDINALITY AS key(attnum, position)
               JOIN pg_attribute AS attribute
                 ON attribute.attrelid = index_state.indrelid
                AND attribute.attnum = key.attnum
               WHERE key.position <= index_state.indnkeyatts
               ORDER BY key.position
             ) AS key_columns,
             pg_get_expr(index_state.indpred, index_state.indrelid) AS predicate
      FROM pg_index AS index_state
      JOIN pg_class AS index_relation ON index_relation.oid = index_state.indexrelid
      JOIN pg_class AS table_relation ON table_relation.oid = index_state.indrelid
      WHERE table_relation.relname = 'access_effects'
        AND index_relation.relname = 'access_effects_target_order_reconciliation_index'
      """)

    assert valid?
    assert ready?
    assert key_columns == ["inserted_at", "id"]

    normalized_predicate = String.downcase(predicate)
    assert normalized_predicate =~ "status"
    assert normalized_predicate =~ "required"
    assert normalized_predicate =~ "pending"
    assert normalized_predicate =~ "failed_retryable"
    refute normalized_predicate =~ "disposition"
  end

  test "reconciliation repairs a stale effective target without churn when evidence already matches" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription
    revision = fixture.revision

    stale =
      establish_effect!(
        subscription,
        revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    bump_aggregate_version!(subscription.id)
    bump_aggregate_version!(subscription.id)
    subscription = reload_subscription!(subscription.id)

    set_updated_at!([stale], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: stale.inserted_at,
               after_inserted_at: stale.inserted_at,
               after_id: @cursor_floor
             )

    assert result.repaired_count == 1
    assert result.noop_count == 0
    assert result.already_covered_count == 0

    rows = access_effect_rows!(subscription.id)
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.status == "superseded"))

    assert Enum.any?(
             rows,
             &(&1.status == "required" and &1.source_version == subscription.aggregate_version)
           )
  end

  test "reconciliation already_covered when target evidence matches current subscription" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription
    revision = fixture.revision

    effect =
      establish_effect!(
        subscription,
        revision,
        %{
          valid_from_at: subscription.current_period_start_at,
          valid_until_at: subscription.current_period_end_at
        }
      )

    set_updated_at!([effect], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: effect.inserted_at,
               after_inserted_at: effect.inserted_at,
               after_id: @cursor_floor
             )

    assert result.already_covered_count == 1
    assert result.repaired_count == 0
    assert length(access_effect_rows!(subscription.id)) == 1
  end

  test "unresolved candidate remains discoverable after lifecycle updates move updated_at past the watermark" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription

    candidate =
      establish_effect!(
        subscription,
        fixture.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    bump_aggregate_version!(subscription.id)

    through_inserted_at = DateTime.add(candidate.inserted_at, 1, :second)
    after_inserted_at = candidate.inserted_at

    assert {:ok, pending} = Facade.mark_access_effect_pending_for_system(candidate)
    assert {:ok, failed} = Facade.mark_access_effect_failed_retryable_for_system(pending)

    moved_updated_at = DateTime.add(through_inserted_at, 1, :second)
    set_updated_at!([failed], moved_updated_at)
    assert access_effect_updated_at!(failed.id) == DateTime.to_naive(moved_updated_at)

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: through_inserted_at,
               after_inserted_at: after_inserted_at,
               after_id: @cursor_floor
             )

    assert result.repaired_count == 1
    assert result.noop_count == 0

    repaired = List.last(access_effect_rows!(subscription.id))
    assert repaired.source_version == subscription.aggregate_version + 1
    assert repaired.status == "required"
  end

  test "reconciliation fails closed when current target evidence is unsupported" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription

    candidate =
      establish_effect!(
        subscription,
        fixture.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    Repo.query!(
      "UPDATE subscriptions SET status = 'expired', aggregate_version = aggregate_version + 1, current_dunning_renewal_attempt_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    assert {:error, %{code: "TARGET_ORDER_UNSUPPORTED_STATE"}} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 10,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )

    [unchanged] = access_effect_rows!(subscription.id)
    assert unchanged.status == "required"
    assert unchanged.source_version == candidate.source_version
  end

  test "past_due keep-grace effect is already_covered when only aggregate_version advanced" do
    fixture = past_due_keep_grace_fixture!()
    subscription = fixture.subscription
    revision = fixture.revision

    effect =
      establish_effect!(
        subscription,
        revision,
        %{
          valid_from_at: subscription.current_period_start_at,
          valid_until_at: subscription.failed_payment_boundary_at
        }
      )

    bump_aggregate_version!(subscription.id)
    bump_aggregate_version!(subscription.id)
    subscription = reload_subscription!(subscription.id)

    set_updated_at!([effect], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: effect.inserted_at,
               after_inserted_at: effect.inserted_at,
               after_id: @cursor_floor
             )

    assert result.already_covered_count == 1
    assert result.repaired_count == 0
    assert length(access_effect_rows!(subscription.id)) == 1
  end

  test "legacy nil-pointer past_due candidate increments noop_count without mutating effects" do
    fixture = subscription_fixture!()
    subscription = fixture.subscription

    candidate =
      establish_effect!(
        subscription,
        fixture.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    Repo.query!(
      """
      UPDATE subscriptions
      SET status = 'past_due',
          current_dunning_renewal_attempt_id = NULL,
          failed_payment_boundary_at = clock_timestamp(),
          past_due_since_at = clock_timestamp(),
          aggregate_version = aggregate_version + 1
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(subscription.id)]
    )

    set_updated_at!([candidate], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )

    assert result.noop_count == 1
    assert result.repaired_count == 0
    assert Map.has_key?(result, :repaired_count)
    refute Map.has_key?(result, :skipped_count)

    [unchanged] = access_effect_rows!(subscription.id)
    assert unchanged.id == candidate.id
    assert unchanged.status == "required"
  end

  test "jc247_b remove_immediately past_due candidate increments noop_count without mutating effects" do
    fixture = past_due_keep_grace_fixture!(access_on_past_due: "remove_immediately")
    subscription = fixture.subscription

    candidate =
      establish_effect!(
        subscription,
        fixture.revision,
        %{
          valid_from_at: subscription.current_period_start_at,
          valid_until_at: subscription.failed_payment_boundary_at
        }
      )

    set_updated_at!([candidate], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )

    assert result.noop_count == 1
    assert result.repaired_count == 0
    assert length(access_effect_rows!(subscription.id)) == 1
  end

  test "reconciliation fails closed when past_due_since_at is missing" do
    fixture = past_due_keep_grace_fixture!()
    subscription = fixture.subscription

    candidate =
      establish_effect!(
        subscription,
        fixture.revision,
        %{
          valid_from_at: subscription.current_period_start_at,
          valid_until_at: subscription.failed_payment_boundary_at
        }
      )

    Repo.query!(
      "UPDATE subscriptions SET past_due_since_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(subscription.id)]
    )

    set_updated_at!([candidate], ~U[2026-10-23 11:00:00.000000Z])

    assert {:error, %{code: "TARGET_ORDER_UNPROVABLE"}} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )
  end

  test "TASK2 legacy nil-pointer cursor page 1 noop then page 2 repairs eligible candidate" do
    legacy = legacy_nil_pointer_fixture!()
    eligible = past_due_keep_grace_fixture!()

    legacy_candidate =
      establish_effect!(
        legacy.subscription,
        legacy.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    eligible_candidate =
      establish_effect!(
        eligible.subscription,
        eligible.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    bump_aggregate_version!(eligible.subscription.id)
    bump_aggregate_version!(eligible.subscription.id)

    t0 = ~U[2026-10-23 10:00:00.000000Z]
    as_of = DateTime.add(t0, 2, :second)
    page_start = DateTime.add(t0, -1, :second)

    set_effect_timestamps!([legacy_candidate], t0)
    set_effect_timestamps!([eligible_candidate], DateTime.add(t0, 1, :second))

    assert {:ok, page_one} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 1,
               as_of: as_of,
               after_inserted_at: page_start,
               after_id: @cursor_floor
             )

    assert page_one.noop_count == 1
    assert page_one.repaired_count == 0
    assert page_one.already_covered_count == 0
    refute Map.has_key?(page_one, :skipped_count)
    assert %{inserted_at: cursor_at, id: cursor_id} = page_one.candidate_cursor

    assert {:ok, page_two} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 1,
               as_of: as_of,
               after_inserted_at: cursor_at,
               after_id: cursor_id
             )

    assert page_two.repaired_count == 1
    assert page_two.noop_count == 0
    assert length(access_effect_rows!(eligible.subscription.id)) == 2
    assert length(access_effect_rows!(legacy.subscription.id)) == 1

    assert {:ok, fresh_sweep} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: as_of,
               after_inserted_at: page_start,
               after_id: @cursor_floor
             )

    assert fresh_sweep.noop_count >= 1
    assert fresh_sweep.repaired_count == 0
  end

  test "TASK2 jc247_b deferred cursor page 1 noop then page 2 repairs eligible candidate" do
    deferred = past_due_keep_grace_fixture!(access_on_past_due: "remove_immediately")
    eligible = past_due_keep_grace_fixture!()

    deferred_candidate =
      establish_effect!(
        deferred.subscription,
        deferred.revision,
        %{
          valid_from_at: deferred.subscription.current_period_start_at,
          valid_until_at: deferred.subscription.failed_payment_boundary_at
        }
      )

    eligible_candidate =
      establish_effect!(
        eligible.subscription,
        eligible.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    bump_aggregate_version!(eligible.subscription.id)
    bump_aggregate_version!(eligible.subscription.id)

    t0 = ~U[2026-10-23 10:00:00.000000Z]
    as_of = DateTime.add(t0, 2, :second)
    page_start = DateTime.add(t0, -1, :second)

    set_effect_timestamps!([deferred_candidate], t0)
    set_effect_timestamps!([eligible_candidate], DateTime.add(t0, 1, :second))

    assert {:ok, page_one} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 1,
               as_of: as_of,
               after_inserted_at: page_start,
               after_id: @cursor_floor
             )

    assert page_one.noop_count == 1
    assert page_one.repaired_count == 0
    assert %{inserted_at: cursor_at, id: cursor_id} = page_one.candidate_cursor

    assert {:ok, page_two} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 1,
               as_of: as_of,
               after_inserted_at: cursor_at,
               after_id: cursor_id
             )

    assert page_two.repaired_count == 1
    assert page_two.noop_count == 0
    assert length(access_effect_rows!(deferred.subscription.id)) == 1
    assert length(access_effect_rows!(eligible.subscription.id)) == 2

    assert {:ok, fresh_sweep} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 50,
               as_of: as_of,
               after_inserted_at: page_start,
               after_id: @cursor_floor
             )

    assert fresh_sweep.noop_count >= 1
    assert fresh_sweep.repaired_count == 0
  end

  test "TASK3 pointer wrong attempt fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!("wrong_pointer", fn fixture ->
      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id),
          Ecto.UUID.dump!(fixture.other_attempt.id)
        ]
      )
    end)
  end

  test "TASK3 attempt owner mismatch fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!("owner_mismatch", fn fixture ->
      foreign = foreign_subscription_attempt_fixture!()

      assert foreign.attempt.subscription_id != fixture.subscription.id

      Repo.query!(
        "UPDATE subscriptions SET current_dunning_renewal_attempt_id = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id),
          Ecto.UUID.dump!(foreign.attempt.id)
        ]
      )
    end)
  end

  test "TASK3 period mismatch fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!("period_mismatch", fn fixture ->
      Repo.query!(
        "UPDATE renewal_attempts SET period_start_at = period_start_at - interval '1 day' WHERE id = $1",
        [Ecto.UUID.dump!(fixture.attempt.id)]
      )
    end)
  end

  test "TASK3 missing boundary fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!("missing_boundary", fn fixture ->
      Repo.query!(
        "UPDATE subscriptions SET failed_payment_boundary_at = NULL WHERE id = $1",
        [Ecto.UUID.dump!(fixture.subscription.id)]
      )
    end)
  end

  test "TASK3 incomplete snapshot fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!(
      "incomplete_snapshot",
      fn fixture ->
        Repo.query!(
          """
          UPDATE renewal_attempts
          SET charged_contract_snapshot =
            jsonb_set(charged_contract_snapshot, '{entitlement_scope_key}', 'null'::jsonb)
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.attempt.id)]
        )
      end,
      allow_validation_error?: true
    )
  end

  test "TASK3 funded revision mismatch fails closed with TARGET_ORDER_UNPROVABLE" do
    assert_malformed_reconciliation_fails!("funded_revision_mismatch", fn fixture ->
      Repo.query!(
        "UPDATE subscriptions SET current_plan_revision_id = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(fixture.subscription.id),
          Ecto.UUID.dump!(fixture.wrong_revision.id)
        ]
      )
    end)
  end

  defp assert_malformed_reconciliation_fails!(_label, mutate, opts \\ []) do
    allow_validation_error? = Keyword.get(opts, :allow_validation_error?, false)
    fixture = past_due_keep_grace_fixture!()

    candidate =
      establish_effect!(
        fixture.subscription,
        fixture.revision,
        %{
          valid_from_at: fixture.subscription.current_period_start_at,
          valid_until_at: fixture.subscription.failed_payment_boundary_at
        }
      )

    set_updated_at!([candidate], ~U[2026-10-23 11:00:00.000000Z])
    mutate.(fixture)

    assert {:error, %{code: code}} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 10,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )

    allowed =
      if allow_validation_error? do
        ["TARGET_ORDER_UNPROVABLE", "IDEMPOTENCY_KEY_REUSE_MISMATCH", "VALIDATION_ERROR"]
      else
        ["TARGET_ORDER_UNPROVABLE", "IDEMPOTENCY_KEY_REUSE_MISMATCH"]
      end

    assert code in allowed

    [unchanged] = access_effect_rows!(fixture.subscription.id)
    assert unchanged.id == candidate.id
    assert unchanged.status == "required"
  end

  test "TASK3 legacy nil-pointer malformed subscription still increments noop_count" do
    legacy = legacy_nil_pointer_fixture!()

    candidate =
      establish_effect!(
        legacy.subscription,
        legacy.revision,
        %{valid_from_at: ~U[2020-01-01 00:00:00.000000Z]}
      )

    set_updated_at!([candidate], ~U[2026-10-23 11:00:00.000000Z])

    assert {:ok, result} =
             Facade.run_access_effect_target_order_reconciliation_for_system(
               limit: 10,
               as_of: candidate.inserted_at,
               after_inserted_at: candidate.inserted_at,
               after_id: @cursor_floor
             )

    assert result.noop_count == 1
    assert result.repaired_count == 0
  end

  defp legacy_nil_pointer_fixture! do
    fixture = subscription_fixture!()
    subscription = fixture.subscription

    Repo.query!(
      """
      UPDATE subscriptions
      SET status = 'past_due',
          current_dunning_renewal_attempt_id = NULL,
          failed_payment_boundary_at = clock_timestamp(),
          past_due_since_at = clock_timestamp(),
          aggregate_version = aggregate_version + 1
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(subscription.id)]
    )

    %{subscription: reload_subscription!(subscription.id), revision: fixture.revision}
  end

  defp past_due_keep_grace_fixture!(opts \\ []) do
    access_on_past_due = Keyword.get(opts, :access_on_past_due, "keep_during_grace")
    customer = SubscriptionsFixtures.create_customer!("jc247_pd_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        grace_period_days: 7,
        max_retry_attempts: 3,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc247-pd"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_jc247_pd",
        started_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: DateTime.add(now, -1, :microsecond)
      })

    boundary_at = DateTime.add(now, 7, :day)

    snapshot = %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => "day",
      "interval_count" => 1,
      "trial_days" => 0,
      "anchor_mode" => "start_anniversary",
      "anchor_day_of_month" => nil,
      "billing_timezone" => "Etc/UTC",
      "term_mode" => "until_canceled",
      "term_cycles" => nil,
      "term_end_at" => nil,
      "access_on_past_due" => access_on_past_due,
      "access_on_cancel" => "keep_until_period_end",
      "grace_period_days" => 7,
      "max_retry_attempts" => 3,
      "retry_schedule_hours" => [0, 24, 72],
      "entitlement_kind" => "membership_access",
      "entitlement_scope_key" => "jc247-pd"
    }

    subscription = reload_subscription!(subscription.id)

    attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          renewal_key: "jc247-pd:#{Ecto.UUID.generate()}",
          period_start_at: subscription.current_period_end_at,
          period_end_at: DateTime.add(subscription.current_period_end_at, 1, :day),
          plan_revision_id: revision.id,
          variant_id: variant.id,
          quantity: 1,
          amount_minor: plan.amount_minor,
          currency: plan.currency,
          expected_subscription_version: subscription.aggregate_version,
          charged_contract_version: 1,
          charged_contract_snapshot: snapshot,
          status: :failed
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    Repo.query!(
      """
      UPDATE subscriptions
      SET status = 'past_due',
          current_dunning_renewal_attempt_id = $2,
          failed_payment_boundary_at = $3,
          past_due_since_at = $4,
          dunning_attempt_count = 1
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(subscription.id),
        Ecto.UUID.dump!(attempt.id),
        boundary_at,
        now
      ]
    )

    subscription = reload_subscription!(subscription.id)

    other_attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          renewal_key: "jc247-pd-other:#{Ecto.UUID.generate()}",
          period_start_at: DateTime.add(subscription.current_period_end_at, -2, :day),
          period_end_at: DateTime.add(subscription.current_period_end_at, -1, :day),
          plan_revision_id: revision.id,
          variant_id: variant.id,
          quantity: 1,
          amount_minor: plan.amount_minor,
          currency: plan.currency,
          expected_subscription_version: subscription.aggregate_version,
          charged_contract_version: 1,
          charged_contract_snapshot: snapshot,
          status: :failed
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    wrong_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        interval_unit: :day,
        interval_count: 1,
        grace_period_days: 7,
        max_retry_attempts: 3,
        entitlement_kind: :membership_access,
        entitlement_scope_key: "jc247-pd-wrong"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, wrong_plan.id)
    wrong_revision = SubscriptionsFixtures.create_plan_revision!(wrong_plan)

    subscription = reload_subscription!(subscription.id)
    attempt_period_start = subscription.current_period_end_at

    %{
      subscription: subscription,
      revision: revision,
      plan: plan,
      variant: variant,
      attempt: attempt,
      other_attempt: other_attempt,
      wrong_revision: wrong_revision,
      boundary_at: boundary_at,
      past_due_since_at: now,
      snapshot: snapshot,
      attempt_period_start: attempt_period_start
    }
  end

  defp foreign_subscription_attempt_fixture! do
    customer = SubscriptionsFixtures.create_customer!("f05_foreign_#{Ecto.UUID.generate()}")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f05-foreign"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, revision: revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider_billing_ref: "pm_f05_foreign"
      })

    subscription = reload_subscription!(subscription.id)

    snapshot = %{
      "version" => 1,
      "subscription_plan_key" => plan.key,
      "interval_unit" => "day",
      "interval_count" => 1,
      "trial_days" => 0,
      "anchor_mode" => "start_anniversary",
      "anchor_day_of_month" => nil,
      "billing_timezone" => "Etc/UTC",
      "term_mode" => "until_canceled",
      "term_cycles" => nil,
      "term_end_at" => nil,
      "access_on_past_due" => "keep_during_grace",
      "access_on_cancel" => "keep_until_period_end",
      "grace_period_days" => 7,
      "max_retry_attempts" => 3,
      "retry_schedule_hours" => [0, 24, 72],
      "entitlement_kind" => "membership_access",
      "entitlement_scope_key" => "f05-foreign"
    }

    attempt =
      RenewalAttempt
      |> Ash.Changeset.for_create(
        :create_or_reuse,
        %{
          subscription_id: subscription.id,
          renewal_key: "f05-foreign:#{Ecto.UUID.generate()}",
          period_start_at: subscription.current_period_end_at,
          period_end_at: DateTime.add(subscription.current_period_end_at, 1, :day),
          plan_revision_id: revision.id,
          variant_id: variant.id,
          quantity: 1,
          amount_minor: plan.amount_minor,
          currency: plan.currency,
          expected_subscription_version: subscription.aggregate_version,
          charged_contract_version: 1,
          charged_contract_snapshot: snapshot,
          status: :failed
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    %{subscription: subscription, attempt: attempt}
  end

  defp subscription_fixture! do
    customer =
      SubscriptionsFixtures.create_customer!("f05_reconcile_#{Ecto.UUID.generate()}")

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        entitlement_kind: :membership_access,
        entitlement_scope_key: "f05-members"
      })

    SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)
  end

  defp establish_effect!(subscription, revision, overrides) do
    attrs =
      %{
        subscription_id: subscription.id,
        source_version: Map.get(overrides, :source_version, subscription.aggregate_version),
        disposition: :effective,
        entitlement_kind: revision.entitlement_kind,
        entitlement_scope_key: revision.entitlement_scope_key,
        valid_from_at: Map.get(overrides, :valid_from_at, subscription.current_period_start_at),
        valid_until_at: Map.get(overrides, :valid_until_at, subscription.current_period_end_at),
        source_order_line_item_id: subscription.source_order_line_item_id,
        contract_change_id: subscription.current_contract_change_id,
        plan_revision_id: revision.id
      }

    assert {:ok, input} = EstablishAccessEffectInput.new(attrs)
    assert {:ok, effect} = Facade.establish_access_effect_for_system(input)
    effect
  end

  defp bump_aggregate_version!(subscription_id) do
    Repo.query!(
      "UPDATE subscriptions SET aggregate_version = aggregate_version + 1 WHERE id = $1",
      [
        Ecto.UUID.dump!(subscription_id)
      ]
    )
  end

  defp reload_subscription!(id) do
    Store.Subscriptions.Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp set_effect_timestamps!(effects, timestamp) do
    Enum.each(effects, fn effect ->
      Repo.query!("UPDATE access_effects SET inserted_at = $2, updated_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(effect.id),
        timestamp
      ])
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

  defp access_effect_updated_at!(effect_id) do
    {:ok, %{rows: [[updated_at]]}} =
      Repo.query("SELECT updated_at FROM access_effects WHERE id = $1", [
        Ecto.UUID.dump!(effect_id)
      ])

    updated_at
  end

  defp access_effect_rows!(subscription_id) do
    {:ok, result} =
      Repo.query(
        """
        SELECT id::text, status, disposition, source_version, valid_from_at, valid_until_at
        FROM access_effects
        WHERE subscription_id = $1
        ORDER BY source_version ASC
        """,
        [Ecto.UUID.dump!(subscription_id)]
      )

    result.rows
    |> Enum.map(fn [id, status, disposition, source_version, from_at, until_at] ->
      %{
        id: id,
        status: status,
        disposition: disposition,
        source_version: source_version,
        valid_from_at: from_at,
        valid_until_at: until_at
      }
    end)
  end
end
