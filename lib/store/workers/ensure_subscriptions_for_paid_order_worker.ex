defmodule Store.Workers.EnsureSubscriptionsForPaidOrderWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) when is_binary(order_id) do
    case SubscriptionsFacade.create_subscriptions_from_paid_order_for_system(order_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing order_id"}
end
