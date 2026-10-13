defmodule Store.Subscriptions.RenewalCollectionAttempt do
  @moduledoc """
  Durable identity and state for one collection within a bound renewal occurrence.
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
      public?(true)
    end

    attribute :dispatch_state, Store.Subscriptions.Types.RenewalCollectionDispatchState do
      allow_nil?(false)
      default(:not_started)
      public?(true)
    end

    attribute :financial_outcome, Store.Subscriptions.Types.RenewalCollectionFinancialOutcome do
      allow_nil?(false)
      default(:unresolved)
      public?(true)
    end

    attribute :reservation_generation_id, :uuid do
      allow_nil?(true)
      public?(false)
    end

    attribute :dispatch_epoch, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
      public?(true)
    end

    attribute :fenced_through_epoch, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
      public?(true)
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

    belongs_to :reservation_generation, Store.Orders.InventoryReservation do
      allow_nil?(true)
      attribute_writable?(true)
      source_attribute(:reservation_generation_id)
      public?(false)
    end
  end

  identities do
    identity(:unique_renewal_attempt_collection_ordinal, [
      :renewal_attempt_id,
      :collection_ordinal
    ])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    read :read_for_renewal_attempt do
      argument :renewal_attempt_id, :uuid do
        allow_nil?(false)
      end

      filter(expr(renewal_attempt_id == ^arg(:renewal_attempt_id)))
      prepare(build(sort: [collection_ordinal: :asc]))
    end

    create :create do
      public?(false)
      accept([:renewal_attempt_id, :collection_ordinal])
    end

    update :assign_reservation_generation do
      public?(false)
      require_atomic?(false)
      accept([:reservation_generation_id])
    end

    update :fence_before_submission do
      public?(false)
      require_atomic?(false)

      accept([
        :dispatch_state,
        :fenced_through_epoch,
        :last_fence_event_id,
        :last_fenced_at
      ])
    end

    update :resume_after_fence do
      public?(false)
      require_atomic?(false)
      accept([:dispatch_state, :dispatch_epoch, :reservation_generation_id])
    end
  end

  code_interface do
    define(:list_for_renewal_attempt,
      action: :read_for_renewal_attempt,
      args: [:renewal_attempt_id]
    )
  end

  postgres do
    table("renewal_collection_attempts")
    repo(Store.Repo)

    identity_index_names(
      unique_renewal_attempt_collection_ordinal:
        "renewal_collection_attempts_attempt_ordinal_index"
    )

    references do
      reference(:renewal_attempt, on_delete: :restrict)
      reference(:payment_intent, on_delete: :restrict)
      reference(:reservation_generation, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(
        :collection_ordinal,
        "renewal_collection_attempts_collection_ordinal_positive_check",
        check: "collection_ordinal > 0"
      )

      check_constraint(
        :dispatch_state,
        "renewal_collection_attempts_dispatch_state_value_check",
        check: "dispatch_state IN ('not_started', 'may_have_been_reached', 'not_submitted')"
      )

      check_constraint(
        :financial_outcome,
        "renewal_collection_attempts_financial_outcome_value_check",
        check:
          "financial_outcome IN ('unresolved', 'requires_action', 'verified_success', 'verified_terminal_financial_non_success')"
      )

      check_constraint(
        :dispatch_epoch,
        "renewal_collection_attempts_dispatch_epoch_fence_check",
        check: """
          dispatch_epoch > 0
          AND fenced_through_epoch >= 0
          AND fenced_through_epoch <= dispatch_epoch
          AND (
            (
              fenced_through_epoch = 0
              AND dispatch_epoch = 1
              AND dispatch_state IN ('not_started', 'may_have_been_reached')
              AND last_fence_event_id IS NULL
              AND last_fenced_at IS NULL
            )
            OR (
              fenced_through_epoch > 0
              AND last_fence_event_id IS NOT NULL
              AND last_fenced_at IS NOT NULL
              AND (
                (dispatch_state = 'not_submitted'
                  AND dispatch_epoch = fenced_through_epoch)
                OR (dispatch_state IN ('not_started', 'may_have_been_reached')
                  AND dispatch_epoch = fenced_through_epoch + 1)
              )
            )
          )
        """
      )

      check_constraint(
        :last_fence_event_id,
        "renewal_collection_attempts_fence_evidence_pair_check",
        check:
          "(fenced_through_epoch = 0 AND last_fence_event_id IS NULL AND last_fenced_at IS NULL) OR (fenced_through_epoch > 0 AND last_fence_event_id IS NOT NULL AND last_fenced_at IS NOT NULL)"
      )

      check_constraint(
        :payment_intent_id,
        "renewal_collection_attempts_financial_outcome_payment_intent_check",
        check: "financial_outcome = 'unresolved' OR payment_intent_id IS NOT NULL"
      )
    end

    custom_indexes do
      index([:renewal_attempt_id],
        unique: true,
        where: "financial_outcome IN ('unresolved', 'requires_action')",
        name: "renewal_collection_attempts_one_active_per_attempt_index"
      )

      index([:payment_intent_id],
        unique: true,
        where: "payment_intent_id IS NOT NULL",
        name: "renewal_collection_attempts_unique_payment_intent_index"
      )

      index([:renewal_attempt_id],
        unique: true,
        where: "financial_outcome = 'verified_success'",
        name: "renewal_collection_attempts_one_success_per_attempt_index"
      )

      index([:reservation_generation_id],
        name: "renewal_collection_attempts_reservation_generation_index"
      )
    end

    custom_statements do
      statement :collection_ordinal_and_success_guard_function do
        after_tables(["renewal_collection_attempts"])

        up("""
        CREATE FUNCTION store_guard_renewal_collection_attempt()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        DECLARE
          expected_ordinal bigint;
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION USING
              ERRCODE = '23514',
              MESSAGE = 'renewal collection history cannot be deleted',
              CONSTRAINT = 'renewal_collection_attempts_durable_history_check';
          END IF;

          IF TG_OP = 'UPDATE' THEN
            IF NEW.renewal_attempt_id <> OLD.renewal_attempt_id
              OR NEW.collection_ordinal <> OLD.collection_ordinal THEN
              RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'renewal collection identity is immutable',
                CONSTRAINT = 'renewal_collection_attempts_identity_immutable_check';
            END IF;

            IF OLD.payment_intent_id IS NOT NULL
              AND NEW.payment_intent_id IS DISTINCT FROM OLD.payment_intent_id THEN
              RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'bound renewal collection payment intent is immutable',
                CONSTRAINT = 'renewal_collection_attempts_payment_intent_immutable_check';
            END IF;

            IF OLD.reservation_generation_id IS DISTINCT FROM NEW.reservation_generation_id
              AND NOT (
                NEW.reservation_generation_id IS NOT NULL
                AND NEW.dispatch_state = 'not_started'
                AND NEW.financial_outcome = 'unresolved'
                AND NEW.fenced_through_epoch = OLD.fenced_through_epoch
                AND NEW.last_fence_event_id IS NOT DISTINCT FROM OLD.last_fence_event_id
                AND NEW.last_fenced_at IS NOT DISTINCT FROM OLD.last_fenced_at
                AND (
                  (
                    OLD.reservation_generation_id IS NULL
                    AND OLD.dispatch_state = 'not_started'
                    AND NEW.dispatch_epoch = OLD.dispatch_epoch
                  )
                  OR (
                    OLD.dispatch_state = 'not_submitted'
                    AND OLD.dispatch_epoch = OLD.fenced_through_epoch
                    AND NEW.dispatch_epoch = OLD.dispatch_epoch + 1
                  )
                )
              ) THEN
              RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'reservation generation may change only when binding or resuming a fenced epoch',
                CONSTRAINT = 'renewal_collection_attempts_reservation_generation_transition_check';
            END IF;

            IF OLD.financial_outcome IN (
              'verified_success',
              'verified_terminal_financial_non_success'
            ) AND NEW.financial_outcome <> OLD.financial_outcome THEN
              RAISE EXCEPTION USING
                ERRCODE = '23514',
                MESSAGE = 'terminal renewal collection outcome cannot regress',
                CONSTRAINT = 'renewal_collection_attempts_terminal_outcome_monotonic_check';
            END IF;

            IF NEW.financial_outcome = 'verified_success'
              AND OLD.financial_outcome <> 'verified_success' THEN
              PERFORM 1
              FROM renewal_attempts
              WHERE id = NEW.renewal_attempt_id
              FOR UPDATE;

              IF EXISTS (
                SELECT 1
                FROM renewal_collection_attempts later
                WHERE later.renewal_attempt_id = NEW.renewal_attempt_id
                  AND later.collection_ordinal > NEW.collection_ordinal
              ) THEN
                RAISE EXCEPTION USING
                  ERRCODE = '23514',
                  MESSAGE = 'verified success cannot follow a later collection ordinal',
                  CONSTRAINT = 'renewal_collection_attempts_success_closes_renewal_check';
              END IF;
            END IF;

            RETURN NEW;
          END IF;

          PERFORM 1
          FROM renewal_attempts
          WHERE id = NEW.renewal_attempt_id
          FOR UPDATE;

          IF EXISTS (
            SELECT 1
            FROM renewal_collection_attempts existing
            WHERE existing.renewal_attempt_id = NEW.renewal_attempt_id
              AND existing.financial_outcome = 'verified_success'
          ) THEN
            RAISE EXCEPTION USING
              ERRCODE = '23514',
              MESSAGE = 'verified success closes the renewal to new collections',
              CONSTRAINT = 'renewal_collection_attempts_success_closes_renewal_check';
          END IF;

          SELECT COALESCE(MAX(collection_ordinal), 0) + 1
          INTO expected_ordinal
          FROM renewal_collection_attempts
          WHERE renewal_attempt_id = NEW.renewal_attempt_id;

          IF NEW.collection_ordinal <> expected_ordinal THEN
            RAISE EXCEPTION USING
              ERRCODE = '23514',
              MESSAGE = 'renewal collection ordinals must be contiguous',
              CONSTRAINT = 'renewal_collection_attempts_ordinal_contiguous_check';
          END IF;

          RETURN NEW;
        END;
        $$;
        """)

        down("""
        DROP FUNCTION IF EXISTS store_guard_renewal_collection_attempt();
        """)
      end

      statement :collection_ordinal_and_success_guard_trigger do
        after_tables(["renewal_collection_attempts"])

        up("""
        CREATE TRIGGER renewal_collection_attempts_guard
        BEFORE INSERT OR UPDATE OR DELETE ON renewal_collection_attempts
        FOR EACH ROW EXECUTE FUNCTION store_guard_renewal_collection_attempt();
        """)

        down("""
        DROP TRIGGER IF EXISTS renewal_collection_attempts_guard ON renewal_collection_attempts;
        """)
      end
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
end
