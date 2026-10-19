defmodule Store.Repo.Migrations.Jc242DurablePeriodBoundaryTargets do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :cancel_at_period_end_at, :utc_datetime_usec

      add :cancel_after_renewal_attempt_id,
          references(:renewal_attempts,
            type: :uuid,
            on_delete: :restrict,
            name: "subscriptions_cancel_after_renewal_attempt_id_fkey"
          )
    end

    execute(legacy_target_preflight_sql())
    execute(legacy_target_backfill_sql())

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

  defp legacy_target_backfill_sql do
    """
    UPDATE subscriptions s
    SET cancel_at_period_end_at = CASE
          WHEN EXISTS (
            SELECT 1
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
              AND EXISTS (
                SELECT 1
                FROM payment_applications pa
                JOIN payment_intents pi
                  ON pi.id = pa.payment_intent_id
                 AND pi.order_id = ra.order_id
                JOIN orders o ON o.id = ra.order_id AND o.state = 'paid'
                WHERE pa.order_id = ra.order_id
                  AND pa.payment_intent_id = ra.payment_intent_id
              )
          ) THEN (
            SELECT ra.period_end_at
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
            LIMIT 1
          )
          WHEN EXISTS (
            SELECT 1
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
          ) THEN NULL
          ELSE s.current_period_end_at
        END,
        cancel_after_renewal_attempt_id = CASE
          WHEN EXISTS (
            SELECT 1
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
              AND NOT EXISTS (
                SELECT 1
                FROM payment_applications pa
                JOIN payment_intents pi
                  ON pi.id = pa.payment_intent_id
                 AND pi.order_id = ra.order_id
                JOIN orders o ON o.id = ra.order_id AND o.state = 'paid'
                WHERE pa.order_id = ra.order_id
                  AND pa.payment_intent_id = ra.payment_intent_id
              )
          ) THEN (
            SELECT ra.id
            FROM renewal_attempts ra
            WHERE ra.subscription_id = s.id
              AND ra.period_start_at = s.current_period_end_at
            LIMIT 1
          )
          ELSE NULL
        END
    WHERE s.cancel_at_period_end = true;
    """
  end
end
