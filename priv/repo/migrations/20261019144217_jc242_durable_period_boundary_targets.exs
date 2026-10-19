defmodule Store.Repo.Migrations.Jc242DurablePeriodBoundaryTargets do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :cancel_at_period_end_at, :utc_datetime_usec

      add :cancel_after_renewal_attempt_id, :uuid
    end

    execute(legacy_target_preflight_sql())
    execute(legacy_target_backfill_sql())

    create unique_index(:renewal_attempts, [:subscription_id, :id],
             name: "renewal_attempts_subscription_id_id_owner_unique_index"
           )

    execute("""
    ALTER TABLE subscriptions
    ADD CONSTRAINT subscriptions_cancel_after_renewal_attempt_owner_fkey
    FOREIGN KEY (id, cancel_after_renewal_attempt_id)
    REFERENCES renewal_attempts (subscription_id, id)
    ON DELETE RESTRICT
    """)

    create constraint(:subscriptions, :subscriptions_scheduled_cancellation_target_check,
             check: """
             (cancel_at_period_end = false AND cancel_at_period_end_at IS NULL AND
               cancel_after_renewal_attempt_id IS NULL) OR
             (cancel_at_period_end = true AND
               num_nonnulls(cancel_at_period_end_at, cancel_after_renewal_attempt_id) = 1)
             """
           )

    create index(:subscriptions, [:cancel_at_period_end_at, :id],
             name: "subscriptions_active_scheduled_cancellation_due_index",
             where:
               "status = 'active' AND cancel_at_period_end = true AND cancel_at_period_end_at IS NOT NULL"
           )

    create index(:subscriptions, [:ended_at, :id],
             name: "subscriptions_scheduled_cancellation_notification_replay_index",
             where: "status = 'canceled' AND canceled_reason = 'canceled_period_end'"
           )
  end

  def down do
    execute("""
    ALTER TABLE subscriptions
    DROP CONSTRAINT IF EXISTS subscriptions_cancel_after_renewal_attempt_owner_fkey
    """)

    drop_if_exists index(:renewal_attempts, [:subscription_id, :id],
                     name: "renewal_attempts_subscription_id_id_owner_unique_index"
                   )

    drop_if_exists index(:subscriptions, [:ended_at, :id],
                     name: "subscriptions_scheduled_cancellation_notification_replay_index"
                   )

    drop_if_exists index(:subscriptions, [:cancel_at_period_end_at, :id],
                     name: "subscriptions_active_scheduled_cancellation_due_index"
                   )

    drop_if_exists constraint(:subscriptions, :subscriptions_scheduled_cancellation_target_check)

    alter table(:subscriptions) do
      remove :cancel_after_renewal_attempt_id
      remove :cancel_at_period_end_at
    end
  end

  @doc false
  def legacy_target_preflight_sql do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM subscriptions s
        WHERE s.cancel_at_period_end = true
          AND s.current_period_end_at IS NULL
      ) THEN
        RAISE EXCEPTION 'JC-242 cannot classify a scheduled cancellation without a funded period boundary';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM subscriptions s
        WHERE s.cancel_at_period_end = true
          AND s.status = 'canceled'
      ) THEN
        RAISE EXCEPTION 'JC-242 cannot migrate a terminal canceled Subscription with an active cancellation instruction';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM subscriptions s
        WHERE s.cancel_at_period_end = true
          AND (
            SELECT count(*)
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
          ) > 1
      ) THEN
        RAISE EXCEPTION 'JC-242 cannot classify multiple renewal attempts at one scheduled boundary';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM subscriptions s
        JOIN renewal_attempts ra
          ON ra.subscription_id = s.id
         AND ra.period_start_at = s.current_period_end_at
        LEFT JOIN orders o ON o.id = ra.order_id
        LEFT JOIN LATERAL (
          SELECT
            count(*) AS application_count,
            count(*) FILTER (
              WHERE pa.payment_intent_id = ra.payment_intent_id
                AND pi.order_id = ra.order_id
            ) AS exact_application_count
          FROM payment_applications pa
          LEFT JOIN payment_intents pi ON pi.id = pa.payment_intent_id
          WHERE pa.order_id = ra.order_id
        ) application ON true
        WHERE s.cancel_at_period_end = true
          AND (
            (ra.order_id IS NULL AND
              (ra.payment_intent_id IS NOT NULL OR ra.status = 'succeeded'))
            OR (ra.order_id IS NOT NULL AND o.id IS NULL)
            OR (
              ra.order_id IS NOT NULL
              AND ra.payment_intent_id IS NULL
              AND (application.application_count > 0 OR o.state = 'paid')
            )
            OR (
              ra.order_id IS NOT NULL
              AND ra.payment_intent_id IS NOT NULL
              AND (
                application.application_count > 1
                OR (
                  application.application_count = 1
                  AND (
                    application.exact_application_count <> 1
                    OR o.state <> 'paid'
                  )
                )
                OR (
                  application.application_count = 0
                  AND (
                    o.state = 'paid'
                    OR ra.status = 'succeeded'
                    OR ra.failure_code = 'RENEWAL_AUTHORITY_WITHDRAWN'
                  )
                )
              )
            )
          )
      ) THEN
        RAISE EXCEPTION 'JC-242 cannot classify ambiguous renewal payment application evidence';
      END IF;
    END $$;
    """
  end

  @doc false
  def legacy_target_backfill_sql do
    """
    WITH targets AS (
      SELECT
        s.id AS subscription_id,
        ra.id AS attempt_id,
        ra.period_end_at AS attempt_period_end_at,
        COALESCE(
          EXISTS (
            SELECT 1
            FROM payment_applications pa
            JOIN payment_intents pi
              ON pi.id = pa.payment_intent_id
             AND pi.order_id = ra.order_id
            JOIN orders o ON o.id = ra.order_id AND o.state = 'paid'
            WHERE pa.order_id = ra.order_id
              AND pa.payment_intent_id = ra.payment_intent_id
          )
          AND s.current_period_start_at = ra.period_start_at
          AND s.current_period_end_at = ra.period_end_at
          AND s.next_renewal_at = ra.period_end_at
          AND s.current_plan_revision_id = ra.plan_revision_id
          AND s.subscription_plan_id = pr.subscription_plan_id
          AND s.variant_id = ra.variant_id
          AND s.quantity = ra.quantity
          AND s.renewal_amount_minor = ra.amount_minor
          AND s.renewal_currency = ra.currency
          AND s.membership_key IS NOT DISTINCT FROM CASE
            WHEN ra.charged_contract_snapshot->>'entitlement_kind' = 'membership_access'
              AND NULLIF(ra.charged_contract_snapshot->>'entitlement_scope_key', '') IS NOT NULL
            THEN ra.charged_contract_snapshot->>'entitlement_scope_key'
            ELSE NULL
          END,
          false
        ) AS commercially_applied
      FROM subscriptions s
      LEFT JOIN renewal_attempts ra
        ON ra.subscription_id = s.id
       AND ra.period_start_at = s.current_period_end_at
      LEFT JOIN plan_revisions pr ON pr.id = ra.plan_revision_id
      WHERE s.cancel_at_period_end = true
    )
    UPDATE subscriptions s
    SET cancel_at_period_end_at = CASE
          WHEN targets.attempt_id IS NULL THEN s.current_period_end_at
          WHEN targets.commercially_applied THEN targets.attempt_period_end_at
          ELSE NULL
        END,
        cancel_after_renewal_attempt_id = CASE
          WHEN targets.attempt_id IS NOT NULL AND NOT targets.commercially_applied
            THEN targets.attempt_id
          ELSE NULL
        END
    FROM targets
    WHERE s.id = targets.subscription_id;
    """
  end
end
