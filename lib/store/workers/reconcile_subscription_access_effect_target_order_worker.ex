defmodule Store.Workers.ReconcileSubscriptionAccessEffectTargetOrderWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, result} <-
           SubscriptionsFacade.run_access_effect_target_order_reconciliation_for_system(opts),
         :ok <- enqueue_next_page(result, Keyword.get(opts, :limit, 100), args) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:discard, _reason} = discard -> discard
    end
  end

  def perform(_job), do: {:discard, "invalid AccessEffect target-order reconciliation job"}

  defp parse_opts(args) do
    with {:ok, as_of} <- parse_datetime(Map.get(args, "as_of")),
         {:ok, after_inserted_at} <- parse_datetime(Map.get(args, "after_inserted_at")),
         {:ok, limit} <- parse_limit(Map.get(args, "limit", 100)),
         :ok <- validate_optional_id(Map.get(args, "after_id")),
         :ok <- validate_cursor_pair(after_inserted_at, Map.get(args, "after_id")) do
      opts = [limit: limit]

      opts = if as_of, do: Keyword.put(opts, :as_of, as_of), else: opts

      opts =
        if after_inserted_at,
          do: Keyword.put(opts, :after_inserted_at, after_inserted_at),
          else: opts

      opts =
        if Map.get(args, "after_id"),
          do: Keyword.put(opts, :after_id, Map.get(args, "after_id")),
          else: opts

      {:ok, opts}
    else
      _ -> {:discard, "invalid AccessEffect target-order reconciliation cursor"}
    end
  end

  defp enqueue_next_page(%{candidate_cursor: nil}, _limit, _args), do: :ok

  defp enqueue_next_page(%{candidate_cursor: cursor} = result, limit, args) do
    continuation = %{
      "as_of" => DateTime.to_iso8601(result.as_of),
      "limit" => limit,
      "after_inserted_at" => DateTime.to_iso8601(cursor.inserted_at),
      "after_id" => cursor.id
    }

    continuation =
      if Map.has_key?(args, "sweep_id"),
        do: Map.put(continuation, "sweep_id", args["sweep_id"]),
        else: continuation

    continuation
    |> new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_optional_id(nil), do: :ok

  defp validate_optional_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> :error
    end
  end

  defp validate_optional_id(_value), do: :error

  defp validate_cursor_pair(nil, nil), do: :ok
  defp validate_cursor_pair(%DateTime{}, id) when is_binary(id), do: :ok
  defp validate_cursor_pair(_timestamp, _id), do: :error

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp parse_limit(value) when is_integer(value) and value >= 1 and value <= 500, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit >= 1 and limit <= 500 -> {:ok, limit}
      _ -> :error
    end
  end

  defp parse_limit(_value), do: :error
end
