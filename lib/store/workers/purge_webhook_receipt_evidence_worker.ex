defmodule Store.Workers.PurgeWebhookReceiptEvidenceWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :ops,
    max_attempts: 1,
    unique: [period: 3600, fields: [:worker]]

  alias Store.Payments.Facade, as: PaymentsFacade

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    opts = [
      limit: parse_integer_arg(args, "limit", 100),
      retention_days:
        parse_integer_arg(
          args,
          "retention_days",
          Application.get_env(:store, :operations, []) |> Keyword.get(:webhook_retention_days, 30)
        )
    ]

    case PaymentsFacade.purge_expired_webhook_evidence_for_system(opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, "invalid args"}

  defp parse_integer_arg(args, key, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
