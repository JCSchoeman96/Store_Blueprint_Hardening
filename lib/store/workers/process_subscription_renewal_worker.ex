defmodule Store.Workers.ProcessSubscriptionRenewalWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id} = args})
      when is_binary(subscription_id) do
    opts =
      case Map.get(args, "renewal_key") do
        renewal_key when is_binary(renewal_key) -> [renewal_key: renewal_key]
        _ -> []
      end

    case SubscriptionsFacade.process_due_subscription_renewal_for_system(subscription_id, opts) do
      {:ok, :processed} -> :ok
      {:ok, :noop} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing subscription_id"}
end
