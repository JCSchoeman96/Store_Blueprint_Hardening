defmodule Store.TestSupport.Sbh1003RollbackFenceSeed do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @spec insert_durable_renewal_contract_evidence!(module(), String.t()) :: :ok
  def insert_durable_renewal_contract_evidence!(repo, renewal_key_prefix)
      when is_atom(repo) and is_binary(renewal_key_prefix) do
    renewal_key = renewal_key_prefix <> Integer.to_string(System.unique_integer([:positive]))
    token = renewal_key_prefix
    plan_key = token <> "-plan"

    ids =
      %{
        user_id: Ecto.UUID.generate(),
        category_id: Ecto.UUID.generate(),
        product_id: Ecto.UUID.generate(),
        variant_id: Ecto.UUID.generate(),
        plan_id: Ecto.UUID.generate(),
        revision_id: Ecto.UUID.generate(),
        order_id: Ecto.UUID.generate(),
        line_item_id: Ecto.UUID.generate(),
        subscription_id: Ecto.UUID.generate(),
        attempt_id: Ecto.UUID.generate()
      }
      |> Map.new(fn {key, value} -> {key, Ecto.UUID.dump!(value)} end)

    repo.transaction(fn ->
      _ = SQL.query!(repo, "SET CONSTRAINTS ALL DEFERRED", [])

      _ =
        SQL.query!(
          repo,
          "INSERT INTO users (id, email) VALUES ($1, $2)",
          [ids.user_id, token <> "@fence-migration.example"]
        )

      _ =
        SQL.query!(
          repo,
          "INSERT INTO catalog_categories (id, slug, name) VALUES ($1, $2, $3)",
          [ids.category_id, token <> "-category", "Fence Migration Category"]
        )

      _ =
        SQL.query!(
          repo,
          """
          INSERT INTO products (
            id, slug, title, status, published_at, default_variant_id, category_id, product_kind
          ) VALUES ($1, $2, $3, 'published', timezone('utc', now()), $4, $5, 'subscription')
          """,
          [
            ids.product_id,
            token <> "-product",
            "Fence Migration Product",
            ids.variant_id,
            ids.category_id
          ]
        )

      _ =
        SQL.query!(
          repo,
          """
          INSERT INTO variants (id, product_id, sku, currency_code, price_minor, status, is_default)
          VALUES ($1, $2, $3, 'USD', 1300, 'active', true)
          """,
          [ids.variant_id, ids.product_id, token <> "-sku"]
        )

      _ =
        SQL.query!(
          repo,
          "INSERT INTO subscription_plans (id, key, name, amount_minor) VALUES ($1, $2, $3, 1300)",
          [ids.plan_id, plan_key, "Fence Migration Plan"]
        )

      _ =
        SQL.query!(
          repo,
          """
          INSERT INTO plan_revisions (id, status, version, amount_minor, subscription_plan_id)
          VALUES ($1, 'effective', 1, 1300, $2)
          """,
          [ids.revision_id, ids.plan_id]
        )

      _ =
        SQL.query!(
          repo,
          "INSERT INTO orders (id, state, order_ref) VALUES ($1, 'pending_payment', $2)",
          [ids.order_id, token <> "-order"]
        )

      _ =
        SQL.query!(
          repo,
          """
          INSERT INTO order_line_items (
            id, order_id, line_no, currency, quantity, unit_price_minor, line_total_minor,
            variant_id_snapshot
          ) VALUES ($1, $2, 1, 'USD', 1, 1300, 1300, $3)
          """,
          [ids.line_item_id, ids.order_id, ids.variant_id]
        )

      _ =
        SQL.query!(
          repo,
          """
            INSERT INTO subscriptions (
            id, user_id, subscription_plan_id, status, provider, billing_mode,
            source_order_id, source_order_line_item_id, variant_id, quantity,
            renewal_amount_minor, renewal_currency, current_plan_revision_id, aggregate_version
          ) VALUES (
            $1, $2, $3, 'active', 'stripe', 'merchant_managed',
            $4, $5, $6, 1, 1300, 'USD', $7, 1
          )
          """,
          [
            ids.subscription_id,
            ids.user_id,
            ids.plan_id,
            ids.order_id,
            ids.line_item_id,
            ids.variant_id,
            ids.revision_id
          ]
        )

      _ =
        SQL.query!(
          repo,
          """
            INSERT INTO renewal_attempts (
            id, subscription_id, period_start_at, period_end_at, renewal_key, status, attempt_no
          ) VALUES (
            $1, $2, timezone('utc', now()), timezone('utc', now()) + interval '1 day', $3, 'pending', 1
          )
          """,
          [ids.attempt_id, ids.subscription_id, renewal_key]
        )

      _ =
        SQL.query!(
          repo,
          """
            UPDATE renewal_attempts AS ra
          SET plan_revision_id = $2,
              variant_id = $3,
              quantity = 1,
              amount_minor = 1300,
              currency = 'USD',
              expected_subscription_version = 1,
              charged_contract_version = 1,
              charged_contract_snapshot = jsonb_build_object(
                'version', 1,
                'subscription_plan_key', sp.key,
                'interval_unit', pr.interval_unit,
                'interval_count', pr.interval_count,
                'trial_days', pr.trial_days,
                'anchor_mode', pr.anchor_mode,
                'anchor_day_of_month', pr.anchor_day_of_month,
                'billing_timezone', pr.billing_timezone,
                'term_mode', pr.term_mode,
                'term_cycles', pr.term_cycles,
                'term_end_at',
                  CASE
                    WHEN pr.term_end_at IS NULL THEN NULL
                    ELSE to_jsonb(to_char(pr.term_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
                  END,
                'access_on_past_due', pr.access_on_past_due,
                'access_on_cancel', pr.access_on_cancel,
                'grace_period_days', pr.grace_period_days,
                'max_retry_attempts', pr.max_retry_attempts,
                'retry_schedule_hours', to_jsonb(pr.retry_schedule_hours),
                'entitlement_kind', to_jsonb(pr.entitlement_kind),
                'entitlement_scope_key', to_jsonb(pr.entitlement_scope_key)
              )
          FROM plan_revisions AS pr
          JOIN subscription_plans AS sp ON sp.id = pr.subscription_plan_id
          WHERE ra.id = $1
            AND pr.id = $2
            AND sp.id = $4
          """,
          [ids.attempt_id, ids.revision_id, ids.variant_id, ids.plan_id]
        )
    end)

    :ok
  end
end
