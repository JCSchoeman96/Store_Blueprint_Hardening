defmodule Store.Workers.ReconcilePaidSubscriptionRenewalWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :subscriptions,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id} = args}) when is_binary(order_id) do
    opts = reconciliation_identity_opts(args)

    case SubscriptionsFacade.reconcile_paid_subscription_renewal_for_system(order_id, opts) do
      {:ok, :reconciled} -> :ok
      {:ok, :noop} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "missing order_id"}

  defp reconciliation_identity_opts(args) do
    Enum.reduce(
      ["renewal_attempt_id", "collection_attempt_id", "payment_intent_id"],
      [],
      fn key, acc ->
        case Map.get(args, key) do
          value when is_binary(value) ->
            [{String.to_existing_atom(key), value} | acc]

          _ ->
            acc
        end
      end
    )
    |> Enum.reverse()
  end
end
