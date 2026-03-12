defmodule Store.Payments.ProviderTask do
  @moduledoc false

  require Logger

  alias Store.Payments.ProviderConfig
  alias Store.Support.Errors.Error

  @task_event [:store, :checkout, :provider_setup_task]

  @type execute_option ::
          {:provider, atom() | String.t()}
          | {:order_id, String.t() | nil}
          | {:checkout_key, String.t() | nil}
          | {:payment_intent_key, String.t() | nil}
          | {:logger_metadata, keyword()}
          | {:timeout_ms, pos_integer()}
          | {:supervisor, module()}
          | {:spawn_fun, (module(), (-> term()) -> Task.t() | term())}
          | {:yield_fun, (term(), timeout() -> {:ok, term()} | {:exit, term()} | nil)}
          | {:shutdown_fun, (term(), term() -> {:ok, term()} | {:exit, term()} | nil)}

  @spec execute((-> {:ok, map()} | {:error, term()}), [execute_option()]) ::
          {:ok, map()} | {:error, Error.t()}
  def execute(fun, opts) when is_function(fun, 0) and is_list(opts) do
    provider = Keyword.fetch!(opts, :provider)
    timeout_ms = Keyword.get(opts, :timeout_ms, ProviderConfig.task_timeout_ms())
    logger_metadata = Keyword.get(opts, :logger_metadata, Logger.metadata())
    supervisor = Keyword.get(opts, :supervisor, Store.Payments.ProviderTaskSupervisor)
    spawn_fun = Keyword.get(opts, :spawn_fun, &Task.Supervisor.async_nolink/2)
    yield_fun = Keyword.get(opts, :yield_fun, &Task.yield/2)
    shutdown_fun = Keyword.get(opts, :shutdown_fun, &Task.shutdown/2)
    telemetry_metadata = telemetry_metadata(opts, provider)
    started_at = System.monotonic_time()

    emit_task_event(:started, telemetry_metadata, 0, :yield)

    task =
      spawn_fun.(supervisor, fn ->
        Logger.metadata(logger_metadata)
        safe_execute(fun)
      end)

    case yield_fun.(task, timeout_ms) do
      {:ok, {:ok, provider_payload}} ->
        emit_task_event(:ok, telemetry_metadata, elapsed(started_at), :yield)
        {:ok, provider_payload}

      {:ok, {:error, {:task_exit, reason}}} ->
        emit_task_event(:task_exit, telemetry_metadata, elapsed(started_at), :yield)
        {:error, task_exit_error(reason, provider)}

      {:ok, {:error, provider_error}} ->
        emit_task_event(:provider_error, telemetry_metadata, elapsed(started_at), :yield)
        {:error, normalize_provider_error(provider_error, provider)}

      {:exit, reason} ->
        emit_task_event(:task_exit, telemetry_metadata, elapsed(started_at), :yield)
        {:error, task_exit_error(reason, provider)}

      nil ->
        handle_shutdown(task, telemetry_metadata, timeout_ms, provider, started_at, shutdown_fun)
    end
  end

  defp handle_shutdown(task, telemetry_metadata, timeout_ms, provider, started_at, shutdown_fun) do
    case shutdown_fun.(task, :brutal_kill) do
      {:ok, {:ok, provider_payload}} ->
        emit_task_event(:ok, telemetry_metadata, elapsed(started_at), :shutdown)
        {:ok, provider_payload}

      {:ok, {:error, {:task_exit, reason}}} ->
        emit_task_event(:task_exit, telemetry_metadata, elapsed(started_at), :shutdown)
        {:error, task_exit_error(reason, provider)}

      {:ok, {:error, provider_error}} ->
        emit_task_event(:provider_error, telemetry_metadata, elapsed(started_at), :shutdown)
        {:error, normalize_provider_error(provider_error, provider)}

      {:exit, reason} ->
        emit_task_event(:task_exit, telemetry_metadata, elapsed(started_at), :shutdown)
        {:error, task_exit_error(reason, provider)}

      nil ->
        emit_task_event(:timeout, telemetry_metadata, elapsed(started_at), :shutdown)

        {:error,
         Error.new("PAYMENT_PROVIDER_TIMEOUT", "payment provider timed out", %{
           provider: provider_to_string(provider),
           timeout_ms: timeout_ms
         })}
    end
  end

  defp normalize_provider_error(%Error{} = provider_error, _provider), do: provider_error

  defp normalize_provider_error(provider_error, provider) do
    Error.new("PAYMENT_PROVIDER_DOWN", exception_message(provider_error), %{
      provider: provider_to_string(provider)
    })
  end

  defp task_exit_error(reason, provider) do
    Error.new("PAYMENT_PROVIDER_DOWN", "payment provider worker crashed", %{
      provider: provider_to_string(provider),
      reason: inspect(reason)
    })
  end

  defp safe_execute(fun) do
    fun.()
  rescue
    exception ->
      {:error, {:task_exit, exception}}
  catch
    kind, reason ->
      {:error, {:task_exit, {kind, reason}}}
  end

  defp telemetry_metadata(opts, provider) do
    %{
      provider: provider_to_string(provider),
      order_id: Keyword.get(opts, :order_id),
      checkout_key: Keyword.get(opts, :checkout_key),
      payment_intent_key: Keyword.get(opts, :payment_intent_key)
    }
  end

  defp emit_task_event(result, metadata, timeout_ms, completion_source) do
    :telemetry.execute(
      @task_event,
      %{duration: timeout_ms, count: 1},
      Map.merge(metadata, %{result: result, completion_source: completion_source})
    )
  end

  defp elapsed(started_at), do: System.monotonic_time() - started_at

  defp provider_to_string(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp provider_to_string(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp provider_to_string(_provider), do: "unknown"

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(other), do: inspect(other)
end
