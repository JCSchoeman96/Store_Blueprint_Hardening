defmodule Store.Workers.ExpirePendingProviderSetupOrdersWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :inventory,
    max_attempts: 10,
    unique: [period: 55, fields: [:worker, :queue]]

  @spec sweep(DateTime.t(), keyword()) ::
          {:ok,
           %{
             swept_count: non_neg_integer(),
             released_count: non_neg_integer(),
             order_ids: [String.t()]
           }}
          | {:error, term()}
  def sweep(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    started_at = System.monotonic_time()

    result =
      Store.Orders.sweep_stale_pending_provider_setup(
        now,
        Keyword.take(opts, [:ttl_seconds, :batch_size])
      )

    emit_telemetry(result, started_at, Keyword.get(opts, :source, :worker))
    result
  end

  @impl Oban.Worker
  def perform(_job) do
    case sweep(DateTime.utc_now()) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_telemetry({:ok, result}, started_at, source) do
    :telemetry.execute(
      [:store, :checkout, :pending_provider_setup, :sweep],
      %{
        duration: System.monotonic_time() - started_at,
        swept_count: result.swept_count,
        released_count: result.released_count
      },
      %{result: :ok, source: source}
    )
  end

  defp emit_telemetry({:error, _reason}, started_at, source) do
    :telemetry.execute(
      [:store, :checkout, :pending_provider_setup, :sweep],
      %{
        duration: System.monotonic_time() - started_at,
        swept_count: 0,
        released_count: 0
      },
      %{result: :error, source: source}
    )
  end
end
