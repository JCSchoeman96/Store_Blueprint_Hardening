defmodule Store.Workers.RunDueSubscriptionRenewalsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: 55, fields: [:worker, :queue]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts = [limit: parse_limit(args)]

    case SubscriptionsFacade.run_due_renewals_for_system(opts) do
      {:ok, _result} -> :ok
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
