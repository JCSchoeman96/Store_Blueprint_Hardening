defmodule Store.Workers.RunDueFailedPaymentSuspensionsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, result} <- SubscriptionsFacade.run_due_failed_payment_suspensions_for_system(opts),
         :ok <- enqueue_next_page(result, Keyword.get(opts, :limit, 100)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:discard, _reason} = discard -> discard
    end
  end

  def perform(_job), do: {:discard, "invalid failed-payment boundary job"}

  defp parse_opts(args) do
    with {:ok, now} <- parse_datetime(Map.get(args, "now")),
         {:ok, after_boundary_at} <- parse_datetime(Map.get(args, "after_boundary_at")),
         {:ok, limit} <- parse_limit(Map.get(args, "limit", 100)),
         after_id when is_nil(after_id) or is_binary(after_id) <- Map.get(args, "after_id") do
      opts = [limit: limit]
      opts = if now, do: Keyword.put(opts, :now, now), else: opts

      opts =
        if after_boundary_at,
          do: Keyword.put(opts, :after_boundary_at, after_boundary_at),
          else: opts

      opts = if after_id, do: Keyword.put(opts, :after_id, after_id), else: opts
      {:ok, opts}
    else
      _ -> {:discard, "invalid failed-payment boundary cursor"}
    end
  end

  defp enqueue_next_page(%{cursor: nil}, _limit), do: :ok

  defp enqueue_next_page(%{cursor: %{timestamp: timestamp, id: id}, now: now}, limit) do
    %{
      "now" => DateTime.to_iso8601(now),
      "after_boundary_at" => DateTime.to_iso8601(timestamp),
      "after_id" => id,
      "limit" => limit
    }
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp parse_limit(value) when is_integer(value) and value in 1..500, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..500 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_limit(_value), do: :error
end
