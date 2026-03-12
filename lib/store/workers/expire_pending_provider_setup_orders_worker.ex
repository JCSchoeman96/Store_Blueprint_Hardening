defmodule Store.Workers.ExpirePendingProviderSetupOrdersWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :inventory,
    max_attempts: 10,
    unique: [period: 55, fields: [:worker, :queue]]

  @spec sweep(DateTime.t(), keyword()) ::
          {:ok,
           %{
             recovered_count: non_neg_integer(),
             recovered_order_ids: [String.t()],
             swept_count: non_neg_integer(),
             released_count: non_neg_integer(),
             order_ids: [String.t()]
           }}
          | {:error, term()}
  def sweep(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    started_at = System.monotonic_time()
    source = Keyword.get(opts, :source, :worker)

    result =
      with {:ok, recovery} <-
             Store.Payments.reconcile_pending_provider_setup(
               limit: Keyword.get(opts, :batch_size, 200),
               source: source
             ),
           {:ok, sweep_result} <-
             Store.Orders.sweep_stale_pending_provider_setup(
               now,
               Keyword.take(opts, [:ttl_seconds, :batch_size])
             ) do
        {:ok,
         %{
           recovered_count: recovery.recovered_count,
           recovered_order_ids: recovery.order_ids,
           swept_count: sweep_result.swept_count,
           released_count: sweep_result.released_count,
           order_ids: sweep_result.order_ids
         }}
      end

    emit_telemetry(result, started_at, source)
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
        recovered_count: Map.get(result, :recovered_count, 0),
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
        recovered_count: 0,
        swept_count: 0,
        released_count: 0
      },
      %{result: :error, source: source}
    )
  end
end
