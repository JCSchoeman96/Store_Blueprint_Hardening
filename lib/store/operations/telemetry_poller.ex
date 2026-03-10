defmodule Store.Operations.TelemetryPoller do
  @moduledoc """
  Periodic backlog and queue-state measurements for production operations.
  """

  alias Ecto.Adapters.SQL

  @spec emit_queue_metrics() :: :ok
  def emit_queue_metrics do
    :telemetry.execute(
      [:store, :ops, :queues],
      %{
        webhook_backlog_age_seconds:
          backlog_age_seconds(
            "webhook_receipts",
            "received_at",
            "processing_status IN ('new', 'processing')"
          ),
        webhook_failed_count: count("webhook_receipts", "processing_status = 'failed'"),
        outbox_backlog_age_seconds:
          backlog_age_seconds(
            "email_outboxes",
            "inserted_at",
            "state IN ('pending', 'processing')"
          ),
        outbox_pending_count: count("email_outboxes", "state = 'pending'"),
        outbox_failed_count: count("email_outboxes", "state = 'failed'"),
        renewal_backlog_age_seconds: subscription_backlog_age_seconds()
      },
      %{}
    )

    :ok
  end

  defp backlog_age_seconds(table, column, predicate) do
    sql = """
    SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(#{column}))), 0)
    FROM #{table}
    WHERE #{predicate}
    """

    case SQL.query(Store.DirectRepo, sql, []) do
      {:ok, %{rows: [[value]]}} when is_number(value) -> value
      _ -> 0
    end
  rescue
    _error -> 0
  end

  defp count(table, predicate) do
    sql = "SELECT COUNT(*) FROM #{table} WHERE #{predicate}"

    case SQL.query(Store.DirectRepo, sql, []) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      _ -> 0
    end
  rescue
    _error -> 0
  end

  defp subscription_backlog_age_seconds do
    sql = """
    SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(next_renew_at))), 0)
    FROM subscriptions
    WHERE next_renew_at IS NOT NULL
      AND next_renew_at <= NOW()
      AND status IN ('active', 'past_due', 'canceling')
    """

    case SQL.query(Store.DirectRepo, sql, []) do
      {:ok, %{rows: [[value]]}} when is_number(value) -> value
      _ -> 0
    end
  rescue
    _error -> 0
  end
end
