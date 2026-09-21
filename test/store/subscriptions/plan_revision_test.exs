defmodule Store.Subscriptions.PlanRevisionTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{PlanRevision, Subscription}
  alias Store.SubscriptionsFixtures

  @commercial_attrs %{
    interval_unit: :month,
    interval_count: 1,
    currency: "USD",
    amount_minor: 1_999,
    anchor_mode: :start_anniversary,
    billing_timezone: "Etc/UTC",
    term_mode: :until_canceled,
    access_on_past_due: :keep_during_grace,
    access_on_cancel: :keep_until_period_end,
    grace_period_days: 7,
    max_retry_attempts: 3,
    retry_schedule_hours: [0, 24, 72]
  }

  setup do
    plan = SubscriptionsFixtures.create_subscription_plan!()
    %{plan: plan}
  end

  test "create_draft persists plan FK and complete commercial contract", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    assert revision.subscription_plan_id == plan.id
    assert revision.status == :draft
    assert revision.version == 1
    assert revision.amount_minor == 1_999
    assert revision.currency == "USD"
    assert revision.interval_unit == :month
    assert revision.interval_count == 1
    assert revision.max_retry_attempts == 3
    assert revision.retry_schedule_hours == [0, 24, 72]
  end

  test "status cannot be supplied to create an effective or retired revision", %{plan: plan} do
    assert {:error, error} =
             PlanRevision
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(@commercial_attrs, %{
                 subscription_plan_id: plan.id,
                 status: :effective
               }),
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert Enum.any?(error.errors, fn err ->
             match?(%Ash.Error.Changes.InvalidAttribute{field: :status}, err) or
               match?(%Ash.Error.Changes.InvalidChanges{}, err)
           end) or
             reload_drafts_for_plan!(plan.id) == []

    assert {:error, _} =
             PlanRevision
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.merge(@commercial_attrs, %{
                 subscription_plan_id: plan.id,
                 status: :retired
               }),
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )
  end

  test "draft commercial edit succeeds and advances optimistic version", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    updated =
      update_draft!(revision, %{amount_minor: 2_499, currency: "usd", billing_timezone: "Etc/UTC"})

    assert updated.amount_minor == 2_499
    assert updated.currency == "USD"
    assert updated.version == revision.version + 1
    assert reload_revision!(revision.id).amount_minor == 2_499
  end

  test "draft to effective succeeds", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)
    published = publish!(revision)

    assert published.status == :effective
    assert published.version == revision.version + 1
    assert reload_revision!(revision.id).status == :effective
  end

  test "effective commercial edit is rejected", %{plan: plan} do
    revision = publish!(create_draft!(plan, @commercial_attrs))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 9_999},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_or_filter_error?(error)
    assert reload_revision!(revision.id).amount_minor == 1_999
  end

  test "effective to retired succeeds", %{plan: plan} do
    revision = publish!(create_draft!(plan, @commercial_attrs))
    retired = retire!(revision)

    assert retired.status == :retired
    assert retired.version == revision.version + 1
    assert reload_revision!(revision.id).status == :retired
  end

  test "retired commercial edit is rejected", %{plan: plan} do
    revision = retire!(publish!(create_draft!(plan, @commercial_attrs)))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 9_999},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_or_filter_error?(error)
    assert reload_revision!(revision.id).amount_minor == 1_999
  end

  test "draft to retired is impossible", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert invalid_state_transition_error?(error)
    assert reload_revision!(revision.id).status == :draft
  end

  test "retired to effective is impossible", %{plan: plan} do
    revision = retire!(publish!(create_draft!(plan, @commercial_attrs)))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert invalid_state_transition_error?(error)
    assert reload_revision!(revision.id).status == :retired
  end

  test "stale draft edit after publish fails and durable row remains effective", %{plan: plan} do
    draft = create_draft!(plan, @commercial_attrs)
    stale_draft = draft

    published = publish!(draft)

    assert {:error, error} =
             stale_draft
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 4_444},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)

    reloaded = reload_revision!(published.id)
    assert reloaded.status == :effective
    assert reloaded.amount_minor == 1_999
  end

  test "stale publisher after committed draft edit fails and draft keeps edited values", %{
    plan: plan
  } do
    draft = create_draft!(plan, @commercial_attrs)
    stale_publisher = draft

    edited = update_draft!(draft, %{amount_minor: 3_333})

    assert {:error, error} =
             stale_publisher
             |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)

    reloaded = reload_revision!(edited.id)
    assert reloaded.status == :draft
    assert reloaded.amount_minor == 3_333
    assert reloaded.version == edited.version
  end

  test "competing edits from the same version cannot both commit", %{plan: plan} do
    draft = create_draft!(plan, @commercial_attrs)
    stale = draft

    assert {:ok, winner} =
             draft
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 2_100},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             stale
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 2_200},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)
    assert reload_revision!(winner.id).amount_minor == 2_100
  end

  test "mutable subscription plan changes after publication do not alter the revision", %{
    plan: plan
  } do
    revision = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 1_500}))

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{amount_minor: 9_999, currency: "EUR", interval_count: 12},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    reloaded = reload_revision!(revision.id)
    assert reloaded.amount_minor == 1_500
    assert reloaded.currency == "USD"
    assert reloaded.interval_count == 1
  end

  test "multiple revisions for one plan remain distinct historical identities", %{plan: plan} do
    revision_a =
      retire!(
        publish!(
          create_draft!(plan, %{
            @commercial_attrs
            | amount_minor: 1_111,
              billing_timezone: "Etc/UTC"
          })
        )
      )

    revision_b = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222}))

    assert revision_a.id != revision_b.id
    assert reload_revision!(revision_a.id).amount_minor == 1_111
    assert reload_revision!(revision_a.id).status == :retired
    assert reload_revision!(revision_b.id).amount_minor == 2_222
    assert reload_revision!(revision_b.id).status == :effective
  end

  test "retired revision preserves commercial fields after a later revision is published", %{
    plan: plan
  } do
    retired =
      retire!(
        publish!(
          create_draft!(plan, %{
            @commercial_attrs
            | amount_minor: 1_111,
              grace_period_days: 14,
              billing_timezone: "Etc/UTC"
          })
        )
      )

    _later = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 5_555}))

    reloaded = reload_revision!(retired.id)
    assert reloaded.status == :retired
    assert reloaded.amount_minor == 1_111
    assert reloaded.grace_period_days == 14
  end

  test "max_retry_attempts = 0 is accepted", %{plan: plan} do
    revision =
      create_draft!(plan, %{
        @commercial_attrs
        | max_retry_attempts: 0,
          retry_schedule_hours: []
      })

    assert revision.max_retry_attempts == 0
    assert revision.retry_schedule_hours == []
    assert reload_revision!(revision.id).max_retry_attempts == 0
  end

  test "invalid anchor, term, retry, and entitlement contract shapes are rejected", %{plan: plan} do
    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 anchor_mode: :fixed_day_of_month,
                 anchor_day_of_month: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 term_mode: :fixed_cycles,
                 term_cycles: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 term_mode: :fixed_end_at,
                 term_end_at: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 max_retry_attempts: 3,
                 retry_schedule_hours: [0]
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 entitlement_kind: :membership_access,
                 entitlement_scope_key: nil
               })
             )
  end

  test "FK prevents orphan plan revision creation" do
    assert {:error, error} =
             PlanRevision
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.put(@commercial_attrs, :subscription_plan_id, Ash.UUID.generate()),
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert fk_violation_error?(error)
  end

  test "no existing subscription is modified or bound as a side effect", %{plan: plan} do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_01_side_effect")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    before = subscription_snapshot!(subscription.id)

    revision = publish!(create_draft!(plan, @commercial_attrs))
    _retired = retire!(revision)
    _another = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 4_321}))

    after_snapshot = subscription_snapshot!(subscription.id)
    assert before == after_snapshot
    refute Map.has_key?(before, :current_plan_revision_id)
  end

  defp create_draft!(plan, attrs) do
    attrs = Map.put(attrs, :subscription_plan_id, plan.id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_draft(plan, attrs) do
    attrs = Map.put(attrs, :subscription_plan_id, plan.id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp update_draft!(revision, attrs) do
    revision
    |> Ash.Changeset.for_update(:update_draft, attrs, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp publish!(revision) do
    revision
    |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp retire!(revision) do
    revision
    |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_revision!(id) do
    PlanRevision
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_drafts_for_plan!(plan_id) do
    PlanRevision
    |> Ash.Query.filter(expr(subscription_plan_id == ^plan_id and status == :draft))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp subscription_snapshot!(id) do
    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    Map.take(subscription, [
      :id,
      :subscription_plan_id,
      :status,
      :renewal_amount_minor,
      :renewal_currency,
      :quantity,
      :updated_at
    ])
  end

  defp stale_record_error?(error) do
    invalid_errors(error)
    |> Enum.any?(&match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_or_filter_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.StaleRecord{}, err) or
        match?(%Ash.Error.Changes.InvalidChanges{}, err)
    end)
  end

  defp invalid_state_transition_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.InvalidAttribute{message: "INVALID_STATE_TRANSITION"}, err) or
        (is_struct(err) and Exception.message(err) =~ "INVALID_STATE_TRANSITION")
    end)
  end

  defp fk_violation_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.InvalidAttribute{field: :subscription_plan_id}, err) or
        match?(%Ash.Error.Changes.InvalidRelationship{}, err) or
        String.contains?(Exception.message(err), "foreign key")
    end)
  end

  defp invalid_errors({:error, %Ash.Error.Invalid{errors: errors}}), do: errors
  defp invalid_errors(%Ash.Error.Invalid{errors: errors}), do: errors
  defp invalid_errors(_), do: []
end
