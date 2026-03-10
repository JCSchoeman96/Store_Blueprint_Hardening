defmodule StoreWeb.PaymentIngressTelemetry do
  @moduledoc false

  alias Store.Support.Errors.Normalize
  alias Store.Support.Telemetry.RepoStats

  @spec measure(atom(), atom(), atom() | String.t(), (-> result)) :: result when result: term()
  def measure(stage, route, provider, fun)
      when is_atom(stage) and is_atom(route) and is_function(fun, 0) do
    started_at = System.monotonic_time()
    result = fun.()
    emit_stage(stage, route, provider, started_at, result, empty_repo_stats())
    result
  end

  @spec capture_repo_stage(atom(), atom(), atom() | String.t(), (-> result)) :: result
        when result: term()
  def capture_repo_stage(stage, route, provider, fun)
      when is_atom(stage) and is_atom(route) and is_function(fun, 0) do
    started_at = System.monotonic_time()
    {result, repo_stats} = RepoStats.capture(fun)
    emit_stage(stage, route, provider, started_at, result, repo_stats)
    result
  end

  @spec emit_response(
          atom(),
          atom() | String.t(),
          integer(),
          non_neg_integer(),
          atom(),
          String.t() | nil
        ) :: :ok
  def emit_response(route, provider, started_at, status, result, error_code \\ nil)
      when is_atom(route) and is_integer(started_at) and is_integer(status) and is_atom(result) do
    :telemetry.execute(
      [:store, :payments, :ingress, :response],
      %{duration: System.monotonic_time() - started_at},
      %{
        route: route,
        provider: provider_to_string(provider),
        result: result,
        status_bucket: status_bucket(status),
        error_code: error_code || "NONE"
      }
    )
  end

  @spec telemetry_result(term()) :: atom()
  def telemetry_result({:ok, %{duplicate?: true}}), do: :duplicate
  def telemetry_result({:ok, :duplicate}), do: :duplicate
  def telemetry_result({:ok, _}), do: :ok
  def telemetry_result({:discard, _}), do: :discard

  def telemetry_result({:error, error}),
    do: normalize_error_code(error) |> result_from_error_code()

  def telemetry_result(_), do: :error

  @spec telemetry_error_code(term()) :: String.t() | nil
  def telemetry_error_code({:error, error}), do: normalize_error_code(error)
  def telemetry_error_code({:discard, _}), do: "VALIDATION_ERROR"
  def telemetry_error_code(_), do: nil

  @spec emit_webhook_received(
          atom(),
          atom() | String.t(),
          map(),
          map(),
          integer(),
          keyword()
        ) :: :ok
  def emit_webhook_received(
        route,
        provider,
        canonical_receipt,
        receipt_result,
        started_at,
        opts \\ []
      )
      when is_atom(route) and is_integer(started_at) and is_map(canonical_receipt) and
             is_map(receipt_result) do
    :telemetry.execute(
      [:store, :payments, :webhook_received],
      %{duration: System.monotonic_time() - started_at},
      %{
        route: route,
        provider: provider_to_string(provider),
        event_type: Map.get(canonical_receipt, :event_type),
        verified: Keyword.get(opts, :verified, true),
        provider_event_id: Map.get(canonical_receipt, :provider_event_id),
        receipt_id: receipt_id(receipt_result),
        duplicate: Map.get(receipt_result, :duplicate?, false)
      }
    )
  end

  @spec emit_webhook_enqueued(
          atom(),
          atom() | String.t(),
          map(),
          map(),
          term(),
          integer()
        ) :: :ok
  def emit_webhook_enqueued(
        route,
        provider,
        canonical_receipt,
        receipt_result,
        enqueue_result,
        started_at
      )
      when is_atom(route) and is_integer(started_at) and is_map(canonical_receipt) and
             is_map(receipt_result) do
    :telemetry.execute(
      [:store, :payments, :webhook_enqueued],
      %{duration: System.monotonic_time() - started_at},
      %{
        route: route,
        provider: provider_to_string(provider),
        event_type: Map.get(canonical_receipt, :event_type),
        provider_event_id: Map.get(canonical_receipt, :provider_event_id),
        receipt_id: receipt_id(receipt_result),
        duplicate: Map.get(receipt_result, :duplicate?, false),
        result: webhook_enqueue_result(enqueue_result, receipt_result)
      }
    )
  end

  defp emit_stage(stage, route, provider, started_at, result, repo_stats)
       when is_atom(stage) and is_atom(route) and is_map(repo_stats) do
    :telemetry.execute(
      [:store, :payments, :ingress, stage],
      %{
        duration: System.monotonic_time() - started_at,
        query_count: Map.get(repo_stats, :query_count, 0),
        queue_time: Map.get(repo_stats, :queue_time, 0),
        query_time: Map.get(repo_stats, :query_time, 0),
        decode_time: Map.get(repo_stats, :decode_time, 0)
      },
      %{
        route: route,
        provider: provider_to_string(provider),
        result: telemetry_result(result),
        error_code: telemetry_error_code(result) || "NONE"
      }
    )
  end

  defp empty_repo_stats do
    %{query_count: 0, queue_time: 0, query_time: 0, decode_time: 0}
  end

  defp provider_to_string(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_to_string(provider) when is_binary(provider), do: provider
  defp provider_to_string(_provider), do: "unknown"

  defp status_bucket(status) when status in 200..299, do: "2xx"
  defp status_bucket(status) when status in 400..499, do: "4xx"
  defp status_bucket(status) when status in 500..599, do: "5xx"
  defp status_bucket(_status), do: "other"

  defp normalize_error_code(error) do
    error
    |> Normalize.normalize()
    |> Map.get(:code, "INTERNAL_ERROR")
  end

  defp result_from_error_code("VALIDATION_ERROR"), do: :discard
  defp result_from_error_code(_code), do: :error

  defp webhook_enqueue_result({:ok, :duplicate}, _receipt_result), do: :duplicate
  defp webhook_enqueue_result({:ok, _job}, _receipt_result), do: :ok
  defp webhook_enqueue_result(_enqueue_result, %{duplicate?: true}), do: :duplicate
  defp webhook_enqueue_result(_enqueue_result, _receipt_result), do: :error

  defp receipt_id(%{receipt: %{id: id}}) when is_binary(id), do: id
  defp receipt_id(_receipt_result), do: nil
end
