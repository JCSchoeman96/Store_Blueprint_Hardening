defmodule Store.Workers.EnqueueMembershipRenewalRemindersWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :comms,
    max_attempts: 5,
    unique: [period: 55 * 60, fields: [:worker, :queue]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts =
      case Map.get(args, "now") do
        %DateTime{} = now ->
          [now: now]

        now when is_binary(now) ->
          case DateTime.from_iso8601(now) do
            {:ok, parsed, _offset} -> [now: parsed]
            _ -> []
          end

        _ ->
          []
      end

    case Store.Comms.enqueue_due_membership_renewal_reminders_for_system(opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
