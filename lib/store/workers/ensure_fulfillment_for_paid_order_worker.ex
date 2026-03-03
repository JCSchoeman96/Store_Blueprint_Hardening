defmodule Store.Workers.EnsureFulfillmentForPaidOrderWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :fulfillment,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Fulfillment.Facade, as: FulfillmentFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) when is_binary(order_id) do
    case FulfillmentFacade.ensure_paid_order_fulfillment_for_system(order_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing order_id"}
end
