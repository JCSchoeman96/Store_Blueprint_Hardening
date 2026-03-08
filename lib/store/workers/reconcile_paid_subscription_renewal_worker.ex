defmodule Store.Workers.ReconcilePaidSubscriptionRenewalWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id} = args}) when is_binary(order_id) do
    opts =
      case Map.get(args, "renewal_attempt_id") do
        renewal_attempt_id when is_binary(renewal_attempt_id) ->
          [renewal_attempt_id: renewal_attempt_id]

        _ ->
          []
      end

    case SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(order_id, opts) do
      {:ok, :reconciled} -> :ok
      {:ok, :noop} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing order_id"}
end
