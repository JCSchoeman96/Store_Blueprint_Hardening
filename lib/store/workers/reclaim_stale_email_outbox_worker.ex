defmodule Store.Workers.ReclaimStaleEmailOutboxWorker do
  @moduledoc false

  use Oban.Worker, queue: :comms, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    case Store.Comms.reclaim_stale_processing_for_system() do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
