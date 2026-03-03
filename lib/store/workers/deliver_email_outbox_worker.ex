defmodule Store.Workers.DeliverEmailOutboxWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :comms,
    max_attempts: 10,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email_outbox_id" => outbox_id}}) when is_binary(outbox_id) do
    case Store.Comms.deliver_outbox_email_for_system(outbox_id) do
      :ok -> :ok
      {:discard, reason} -> {:discard, inspect(reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing email_outbox_id"}
end
