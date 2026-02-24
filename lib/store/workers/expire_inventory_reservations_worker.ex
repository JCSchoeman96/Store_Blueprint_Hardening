defmodule Store.Workers.ExpireInventoryReservationsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :inventory,
    max_attempts: 10,
    unique: [period: 55, fields: [:worker, :queue]]

  @impl Oban.Worker
  def perform(_job) do
    case Store.Orders.expire_reservations(DateTime.utc_now()) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
