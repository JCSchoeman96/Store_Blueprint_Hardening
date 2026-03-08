defmodule Store.Workers.RunDueSubscriptionRenewalsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Workers.ProcessSubscriptionRenewalWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts = [limit: parse_limit(args)]

    case SubscriptionsFacade.list_due_renewal_jobs_for_system(opts) do
      {:ok, due_jobs} ->
        enqueue_due_jobs(due_jobs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_due_jobs(due_jobs) do
    Enum.reduce_while(due_jobs, :ok, fn due_job, :ok ->
      case enqueue_due_job(due_job) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp enqueue_due_job(due_job) do
    %{
      "subscription_id" => due_job.subscription_id,
      "renewal_key" => due_job.renewal_key
    }
    |> ProcessSubscriptionRenewalWorker.new(schedule_in: due_job.schedule_in)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_limit(args) do
    case Map.get(args, "limit", 100) do
      value when is_integer(value) and value > 0 and value <= 500 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 and parsed <= 500 -> parsed
          _ -> 100
        end

      _ ->
        100
    end
  end
end
