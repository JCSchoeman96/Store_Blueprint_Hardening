defmodule Store.Digital.Workers.IssueGrantsForPaidOrderWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :digital,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Digital.Facade, as: DigitalFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id}}) when is_binary(order_id) do
    case DigitalFacade.ensure_paid_order_download_grants_for_system(order_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing order_id"}
end
