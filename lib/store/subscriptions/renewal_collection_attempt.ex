defmodule Store.Subscriptions.RenewalCollectionAttempt do
  @moduledoc """
  Durable identity and independent dispatch/financial evidence for one collection
  under a bound RenewalAttempt.

  `dispatch_state` records whether a provider request may have been reached for
  `dispatch_epoch`. `financial_outcome` records the separately verified payment
  result. A pre-submission fence changes only dispatch evidence and reservation
  ownership; it never establishes financial non-success.
  """

  import Ash.Expr

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  attributes do
    uuid_v7_primary_key(:id)

    attribute :collection_ordinal, :integer do
      allow_nil?(false)
      constraints(min: 1)
      public?(false)
    end

    attribute :dispatch_state, Store.Subscriptions.Types.RenewalCollectionDispatchState do
      allow_nil?(false)
      default(:not_started)
      public?(false)
    end

    attribute :financial_outcome, Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
      allow_nil?(false)
      default(:unresolved)
      public?(false)
    end

    attribute :reservation_generation_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :dispatch_epoch, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(false)
    end

    attribute :fenced_through_epoch, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(false)
    end

    attribute :last_fence_event_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :last_fenced_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :renewal_attempt, Store.Subscriptions.RenewalAttempt do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end

    belongs_to :payment_intent, Store.Payments.PaymentIntent do
      allow_nil?(true)
      attribute_writable?(true)
      public?(false)
    end
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create do
      public?(false)
      accept([:renewal_attempt_id, :collection_ordinal])
    end

    update :assign_reservation_generation do
      public?(false)
      require_atomic?(false)

      argument :expected_dispatch_epoch, :integer do
        allow_nil?(false)
      end

      argument :reservation_generation_id, :uuid do
        allow_nil?(false)
      end

      accept([])
      change(filter(expr(dispatch_state == :not_started)))
      change(filter(expr(dispatch_epoch == ^arg(:expected_dispatch_epoch))))
      change(filter(expr(is_nil(reservation_generation_id))))
      change(set_attribute(:reservation_generation_id, arg(:reservation_generation_id)))
    end

    update :claim_dispatch do
      public?(false)
      require_atomic?(false)

      argument :expected_dispatch_epoch, :integer do
        allow_nil?(false)
      end

      accept([])
      change(filter(expr(dispatch_state == :not_started)))
      change(filter(expr(dispatch_epoch == ^arg(:expected_dispatch_epoch))))
      change(set_attribute(:dispatch_state, :may_have_been_reached))
    end

    update :fence_before_submission do
      public?(false)
      require_atomic?(false)

      argument :expected_dispatch_epoch, :integer do
        allow_nil?(false)
      end

      argument :fence_event_id, :uuid do
        allow_nil?(false)
      end

      argument :fenced_at, :utc_datetime_usec do
        allow_nil?(false)
      end

      accept([])
      change(filter(expr(dispatch_state == :not_started)))
      change(filter(expr(dispatch_epoch == ^arg(:expected_dispatch_epoch))))
      change(set_attribute(:dispatch_state, :not_submitted))
      change(set_attribute(:fenced_through_epoch, arg(:expected_dispatch_epoch)))
      change(set_attribute(:last_fence_event_id, arg(:fence_event_id)))
      change(set_attribute(:last_fenced_at, arg(:fenced_at)))
    end

    update :resume_after_fence do
      public?(false)
      require_atomic?(false)

      argument :expected_dispatch_epoch, :integer do
        allow_nil?(false)
      end

      argument :next_dispatch_epoch, :integer do
        allow_nil?(false)
      end

      argument :reservation_generation_id, :uuid do
        allow_nil?(true)
      end

      accept([])
      change(filter(expr(dispatch_state == :not_submitted)))
      change(filter(expr(dispatch_epoch == ^arg(:expected_dispatch_epoch))))
      change(filter(expr(fenced_through_epoch == ^arg(:expected_dispatch_epoch))))
      change(filter(expr(financial_outcome == :unresolved)))
      change(set_attribute(:dispatch_state, :not_started))
      change(set_attribute(:dispatch_epoch, arg(:next_dispatch_epoch)))
      change(set_attribute(:reservation_generation_id, arg(:reservation_generation_id)))

      validate(fn changeset, _context ->
        expected = Ash.Changeset.get_argument(changeset, :expected_dispatch_epoch)
        next = Ash.Changeset.get_argument(changeset, :next_dispatch_epoch)

        if next == expected + 1 do
          :ok
        else
          {:error, field: :dispatch_epoch, message: "dispatch epochs must advance by exactly one"}
        end
      end)
    end

    update :attach_payment_intent do
      public?(false)
      require_atomic?(false)

      argument :payment_intent_id, :uuid do
        allow_nil?(false)
      end

      accept([])
      change(filter(expr(is_nil(payment_intent_id))))
      change(set_attribute(:payment_intent_id, arg(:payment_intent_id)))
    end

    update :record_financial_outcome do
      public?(false)
      require_atomic?(false)

      argument :expected_financial_outcome,
               Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
        allow_nil?(false)
      end

      argument :financial_outcome,
               Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
        allow_nil?(false)
      end

      accept([])
      change(filter(expr(financial_outcome == ^arg(:expected_financial_outcome))))
      change(filter(expr(dispatch_state == :may_have_been_reached)))
      change(set_attribute(:financial_outcome, arg(:financial_outcome)))

      validate(fn changeset, _context ->
        from = changeset.data.financial_outcome
        to = Ash.Changeset.get_argument(changeset, :financial_outcome)

        if valid_financial_transition?(from, to) do
          :ok
        else
          {:error,
           field: :financial_outcome, message: "terminal financial outcome cannot regress"}
        end
      end)
    end
  end

  postgres do
    table("renewal_collection_attempts")
    repo(Store.Repo)

    references do
      reference(:renewal_attempt, on_delete: :restrict)
      reference(:payment_intent, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(
        :dispatch_state,
        "renewal_collection_attempts_dispatch_state_check",
        check: "dispatch_state IN ('not_started', 'may_have_been_reached', 'not_submitted')"
      )

      check_constraint(
        :financial_outcome,
        "renewal_collection_attempts_financial_outcome_check",
        check:
          "financial_outcome IN ('unresolved', 'requires_action', 'verified_success', 'verified_terminal_financial_non_success')"
      )

      check_constraint(
        :collection_ordinal,
        "renewal_collection_attempts_collection_ordinal_positive_check",
        check: "collection_ordinal > 0"
      )

      check_constraint(
        :dispatch_epoch,
        "renewal_collection_attempts_epoch_evidence_check",
        check: """
        dispatch_epoch > 0
        AND fenced_through_epoch >= 0
        AND fenced_through_epoch <= dispatch_epoch
        AND (
          (dispatch_state = 'not_submitted' AND fenced_through_epoch = dispatch_epoch)
          OR
          (dispatch_state <> 'not_submitted' AND fenced_through_epoch + 1 = dispatch_epoch)
        )
        AND (
          (fenced_through_epoch = 0 AND last_fence_event_id IS NULL AND last_fenced_at IS NULL)
          OR
          (fenced_through_epoch > 0 AND last_fence_event_id IS NOT NULL AND last_fenced_at IS NOT NULL)
        )
        AND (
          (dispatch_state = 'may_have_been_reached')
          OR
          (dispatch_state IN ('not_started', 'not_submitted') AND financial_outcome = 'unresolved')
        )
        """
      )

      check_constraint(
        :financial_outcome,
        "renewal_collection_attempts_outcome_payment_intent_check",
        check: "financial_outcome = 'unresolved' OR payment_intent_id IS NOT NULL"
      )
    end

    custom_indexes do
      index([:renewal_attempt_id, :collection_ordinal],
        name: "renewal_collection_attempts_attempt_ordinal_index",
        unique: true
      )

      index([:renewal_attempt_id],
        name: "renewal_collection_attempts_one_active_index",
        unique: true,
        where: "financial_outcome IN ('unresolved', 'requires_action')"
      )

      index([:payment_intent_id],
        name: "renewal_collection_attempts_payment_intent_index",
        unique: true,
        where: "payment_intent_id IS NOT NULL"
      )
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin, :support]})
    end

    policy action_type([:create, :update]) do
      access_type(:runtime)
      authorize_if(context_equals(:system?, true))
      authorize_if({Store.Admin.Checks.HasRole, roles: [:super_admin, :admin]})
    end
  end

  defp valid_financial_transition?(:unresolved, outcome),
    do: outcome in [:requires_action, :verified_success, :verified_terminal_financial_non_success]

  defp valid_financial_transition?(:requires_action, outcome),
    do: outcome in [:verified_success, :verified_terminal_financial_non_success]

  defp valid_financial_transition?(outcome, outcome), do: true
  defp valid_financial_transition?(_from, _to), do: false
end
