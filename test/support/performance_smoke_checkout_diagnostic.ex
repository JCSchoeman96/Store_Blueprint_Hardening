defmodule Store.PerformanceSmoke.CheckoutDiagnostic do
  @moduledoc false

  @writer_timeout_ms 5_000
  @sensitive_keys MapSet.new([
                    "authorization",
                    "bind",
                    "bind_params",
                    "cookie",
                    "cookie_value",
                    "credential",
                    "credentials",
                    "headers",
                    "params",
                    "password",
                    "provider_secret",
                    "query",
                    "secret",
                    "sql",
                    "token"
                  ])

  @recordable_states [:raw_open, :running, :workload_complete, :workload_failed]

  @transitions %{
    configured: [:raw_open],
    raw_open: [:running],
    running: [:workload_complete, :workload_failed],
    workload_complete: [:raw_sealed],
    workload_failed: [:raw_sealed],
    raw_sealed: [:aggregating],
    aggregating: [:aggregated, :aggregation_failed],
    aggregated: [:reporting],
    aggregation_failed: [:reporting],
    reporting: [:complete, :evidence_incomplete, :artifact_failed]
  }

  defmodule Input do
    @moduledoc false

    @enforce_keys [
      :run_id,
      :profile,
      :worker_count,
      :variant_count,
      :store_repo_pool_size,
      :direct_repo_pool_size,
      :observer_interval_ms,
      :seed,
      :timeout,
      :provider_mode,
      :artifact_directory
    ]

    defstruct [
      :run_id,
      :profile,
      :worker_count,
      :variant_count,
      :store_repo_pool_size,
      :direct_repo_pool_size,
      :observer_interval_ms,
      :seed,
      :timeout,
      :provider_mode,
      :artifact_directory,
      max_buffered_events: 8_192,
      flush_interval_ms: 25
    ]

    @type t :: %__MODULE__{
            run_id: String.t(),
            profile: atom() | String.t(),
            worker_count: pos_integer(),
            variant_count: pos_integer(),
            store_repo_pool_size: pos_integer(),
            direct_repo_pool_size: pos_integer(),
            observer_interval_ms: pos_integer(),
            seed: integer() | String.t(),
            timeout: pos_integer() | :infinity,
            provider_mode: atom() | String.t(),
            artifact_directory: String.t(),
            max_buffered_events: pos_integer(),
            flush_interval_ms: pos_integer()
          }

    @fields [
      :run_id,
      :profile,
      :worker_count,
      :variant_count,
      :store_repo_pool_size,
      :direct_repo_pool_size,
      :observer_interval_ms,
      :seed,
      :timeout,
      :provider_mode,
      :artifact_directory,
      :max_buffered_events,
      :flush_interval_ms
    ]

    @spec new(map() | keyword()) :: {:ok, t()} | {:error, map()}
    def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

    def new(attrs) when is_map(attrs) do
      defaults = %{
        max_buffered_events: 8_192,
        flush_interval_ms: 25
      }

      attrs = Map.merge(defaults, attrs)

      with :ok <- validate_keys(attrs),
           :ok <- validate_required(attrs),
           :ok <- validate_binary(attrs, :run_id),
           :ok <- validate_choice(attrs, :profile),
           :ok <- validate_choice(attrs, :provider_mode),
           :ok <- validate_binary(attrs, :artifact_directory),
           :ok <- validate_positive(attrs, :worker_count),
           :ok <- validate_positive(attrs, :variant_count),
           :ok <- validate_positive(attrs, :store_repo_pool_size),
           :ok <- validate_positive(attrs, :direct_repo_pool_size),
           :ok <- validate_positive(attrs, :observer_interval_ms),
           :ok <- validate_positive(attrs, :max_buffered_events),
           :ok <- validate_positive(attrs, :flush_interval_ms),
           :ok <- validate_timeout(attrs.timeout),
           :ok <- validate_seed(attrs.seed) do
        {:ok, struct!(__MODULE__, attrs)}
      end
    end

    def new(_attrs),
      do: {:error, %{kind: :invalid_input, field: :input, reason: :expected_map_or_keyword}}

    @spec from_config(map(), keyword()) :: {:ok, t()} | {:error, map()}
    def from_config(config, opts \\ []) when is_map(config) and is_list(opts) do
      run_id = Map.fetch!(config, :run_id)

      attrs = %{
        run_id: run_id,
        profile: Map.fetch!(config, :profile),
        worker_count: Map.fetch!(config, :concurrency_users),
        variant_count: Map.fetch!(config, :checkout_variant_pool_size),
        store_repo_pool_size: Map.fetch!(config, :repo_pool_size),
        direct_repo_pool_size: Map.fetch!(config, :direct_repo_pool_size),
        observer_interval_ms: Map.fetch!(config, :observer_interval_ms),
        seed: Map.get(config, :seed, Map.get(config, :chaos_seed, "diagnostic")),
        timeout: Map.get(config, :timeout, :infinity),
        provider_mode: Map.get(config, :payment_provider, "stub"),
        artifact_directory:
          Keyword.get(opts, :artifact_directory, Path.join("tmp/perf", "checkout_diagnostic"))
      }

      new(Map.merge(attrs, Map.new(opts)))
    end

    @spec public_map(t()) :: map()
    def public_map(%__MODULE__{} = input) do
      input
      |> Map.from_struct()
      |> Map.update!(:profile, &to_string/1)
      |> Map.update!(:provider_mode, &to_string/1)
    end

    defp validate_keys(attrs) do
      case Map.keys(attrs) -- @fields do
        [] -> :ok
        [field | _] -> {:error, %{kind: :invalid_input, field: field, reason: :unknown_field}}
      end
    end

    defp validate_required(attrs) do
      Enum.find_value(@enforce_keys, :ok, fn field ->
        value = Map.get(attrs, field)

        if is_nil(value) or value == "" do
          {:error, %{kind: :invalid_input, field: field, reason: :required}}
        end
      end)
    end

    defp validate_binary(attrs, field) do
      if is_binary(Map.get(attrs, field)) and byte_size(Map.fetch!(attrs, field)) > 0 do
        :ok
      else
        {:error, %{kind: :invalid_input, field: field, reason: :non_empty_string_required}}
      end
    end

    defp validate_choice(attrs, field) do
      value = Map.get(attrs, field)

      if (is_atom(value) or is_binary(value)) and value not in ["", nil] do
        :ok
      else
        {:error, %{kind: :invalid_input, field: field, reason: :atom_or_string_required}}
      end
    end

    defp validate_positive(attrs, field) do
      if is_integer(Map.get(attrs, field)) and Map.fetch!(attrs, field) > 0 do
        :ok
      else
        {:error, %{kind: :invalid_input, field: field, reason: :positive_integer_required}}
      end
    end

    defp validate_timeout(:infinity), do: :ok

    defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok

    defp validate_timeout(_timeout),
      do: {:error, %{kind: :invalid_input, field: :timeout, reason: :positive_timeout_required}}

    defp validate_seed(seed) when is_integer(seed), do: :ok

    defp validate_seed(seed) when is_binary(seed) and byte_size(seed) > 0, do: :ok

    defp validate_seed(_seed),
      do: {:error, %{kind: :invalid_input, field: :seed, reason: :integer_required}}
  end

  defmodule Result do
    @moduledoc false

    defstruct status: :ok,
              lifecycle_state: :configured,
              input: nil,
              workload: %{},
              correctness: %{},
              observer_summary: nil,
              observer: %{},
              telemetry: %{},
              artifacts: %{},
              errors: [],
              evidence: %{},
              aggregate: nil,
              report: nil

    @type t :: %__MODULE__{}
  end

  defmodule Session do
    @moduledoc false

    defstruct state: :configured,
              input: nil,
              raw_path: nil,
              aggregate_path: nil,
              final_report_path: nil,
              events_table: nil,
              meta_table: nil,
              writer_pid: nil,
              handler_ids: [],
              workload: %{},
              correctness: %{},
              observer_summary: nil,
              errors: []

    @type t :: %__MODULE__{}
  end

  @spec transition_state(atom(), atom()) :: {:ok, atom()} | {:error, map()}
  def transition_state(from, to) when is_atom(from) and is_atom(to) do
    if to in Map.get(@transitions, from, []) do
      {:ok, to}
    else
      {:error, %{reason: :invalid_transition, from: from, to: to}}
    end
  end

  @spec walk_lifecycle(atom(), [{atom(), atom()}]) :: {:ok, atom()} | {:error, map()}
  def walk_lifecycle(state, transitions) when is_atom(state) and is_list(transitions) do
    Enum.reduce_while(transitions, {:ok, state}, fn
      {from, to}, {:ok, current} when current == from ->
        case transition_state(current, to) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {from, to}, {:ok, current} ->
        {:halt,
         {:error, %{reason: :unexpected_lifecycle_state, expected: from, actual: current, to: to}}}

      transition, {:ok, current} ->
        {:halt,
         {:error, %{reason: :invalid_transition_spec, state: current, transition: transition}}}
    end)
  end

  @spec run(Input.t(), (Session.t() -> term()), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  def run(input, workload_fun, opts \\ [])

  def run(%Input{} = input, workload_fun, opts)
      when is_function(workload_fun, 1) and is_list(opts) do
    case open(input) do
      {:ok, session} -> execute_run(session, workload_fun, opts)
      {:error, error} -> {:error, artifact_result(input, error)}
    end
  end

  def run(_input, _workload_fun, _opts) do
    result = %Result{
      status: :instrumentation_error,
      lifecycle_state: :artifact_failed,
      errors: [%{kind: :instrumentation, code: :invalid_run_arguments}]
    }

    {:error, result}
  end

  @spec record(Session.t(), atom() | String.t(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record(%Session{} = session, event_type, payload) when is_map(payload) do
    if session.state in @recordable_states do
      insert_event(session, to_string(event_type), json_safe(payload))
    else
      {:error, %{kind: :instrumentation, code: :session_not_recordable, state: session.state}}
    end
  end

  @spec record_phase(Session.t(), atom() | String.t(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record_phase(session, phase, data \\ %{}) when is_map(data) do
    record(session, :phase, Map.put(data, :phase, to_string(phase)))
  end

  @spec record_worker_sync(Session.t(), map()) :: {:ok, pos_integer()} | {:error, map()}
  def record_worker_sync(session, data) when is_map(data), do: record(session, :worker_sync, data)

  @spec record_inventory_subphase(Session.t(), map()) :: {:ok, pos_integer()} | {:error, map()}
  def record_inventory_subphase(session, data) when is_map(data),
    do: record(session, :inventory_subphase, data)

  @spec record_instrumentation_error(Session.t(), term()) :: :ok | {:error, map()}
  def record_instrumentation_error(%Session{} = session, reason) do
    if session.state in @recordable_states do
      :ets.update_counter(
        session.meta_table,
        :instrumentation_errors,
        {2, 1},
        {:instrumentation_errors, 0}
      )

      case record(session, :instrumentation_error, %{code: error_code(reason)}) do
        {:ok, _sequence} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      {:error, %{kind: :instrumentation, code: :session_not_recordable, state: session.state}}
    end
  end

  @spec record_repo_query(Session.t(), map(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record_repo_query(%Session{} = session, measurements, metadata)
      when is_map(measurements) and is_map(metadata) do
    record(session, :repo_query, %{
      source: safe_string(Map.get(metadata, :source, Map.get(metadata, "source", "unknown"))),
      query_identity: query_identity(Map.get(metadata, :query, Map.get(metadata, "query"))),
      parameter_count:
        parameter_count(Map.get(metadata, :params, Map.get(metadata, "params", []))),
      query_time_ms:
        native_to_ms(Map.get(measurements, :query_time, Map.get(measurements, "query_time", 0))),
      queue_time_ms:
        native_to_ms(Map.get(measurements, :queue_time, Map.get(measurements, "queue_time", 0))),
      phase: safe_string(Map.get(metadata, :phase, Map.get(metadata, "phase", "untracked")))
    })
  end

  @spec record_checkout_step(Session.t(), map(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record_checkout_step(%Session{} = session, measurements, metadata)
      when is_map(measurements) and is_map(metadata) do
    record(session, :checkout_step, %{
      step: safe_string(Map.get(metadata, :step, Map.get(metadata, "step", "unknown"))),
      result: safe_result(Map.get(metadata, :result, Map.get(metadata, "result"))),
      duration_ms:
        native_to_ms(Map.get(measurements, :duration, Map.get(measurements, "duration", 0))),
      query_count: numeric_or_zero(Map.get(measurements, :query_count, 0)),
      queue_time_ms:
        native_to_ms(Map.get(measurements, :queue_time, Map.get(measurements, "queue_time", 0))),
      query_time_ms:
        native_to_ms(Map.get(measurements, :query_time, Map.get(measurements, "query_time", 0))),
      decode_time_ms:
        native_to_ms(Map.get(measurements, :decode_time, Map.get(measurements, "decode_time", 0)))
    })
  end

  @spec record_observer_sample(Session.t(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record_observer_sample(%Session{} = session, sample) when is_map(sample) do
    if session.state in @recordable_states do
      sample_sequence =
        :ets.update_counter(
          session.meta_table,
          :observer_sequence,
          {2, 1},
          {:observer_sequence, 0}
        )

      payload = observer_payload(sample, sample_sequence)

      case record(session, :observer_sample, payload) do
        {:ok, _event_sequence} -> {:ok, sample_sequence}
        {:error, error} -> {:error, error}
      end
    else
      {:error, %{kind: :instrumentation, code: :session_not_recordable, state: session.state}}
    end
  end

  @spec record_observer_summary(Session.t(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def record_observer_summary(session, summary) when is_map(summary) do
    record(session, :observer_summary, summary_without_backend_queries(summary))
  end

  @spec handle_repo_query_event(list(), map(), map(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def handle_repo_query_event(_event, measurements, metadata, %{session: session}) do
    record_repo_query(session, measurements, metadata)
  end

  @spec handle_checkout_step_event(list(), map(), map(), map()) ::
          {:ok, pos_integer()} | {:error, map()}
  def handle_checkout_step_event(_event, measurements, metadata, %{session: session}) do
    record_checkout_step(session, measurements, metadata)
  end

  @spec buffer_stats(Session.t()) :: map()
  def buffer_stats(%Session{} = session) do
    %{
      buffered_events: meta_value(session.meta_table, :buffered, 0),
      max_buffered_events: session.input.max_buffered_events,
      max_observed_buffered_events: meta_value(session.meta_table, :max_observed_buffered, 0),
      dropped_events: meta_value(session.meta_table, :dropped, 0)
    }
  end

  @spec read_raw_events(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_raw_events(raw_path) when is_binary(raw_path) do
    raw_path
    |> File.stream!([], :line)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(String.trim(line)) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [File.Error] -> {:error, error}
  end

  @spec read_raw_events!(String.t()) :: [map()]
  def read_raw_events!(raw_path) do
    case read_raw_events(raw_path) do
      {:ok, events} ->
        events

      {:error, reason} ->
        raise "unable to read checkout diagnostic raw artifact: #{inspect(reason)}"
    end
  end

  @spec aggregate_raw(String.t()) :: {:ok, map()} | {:error, term()}
  def aggregate_raw(raw_path) when is_binary(raw_path) do
    initial = %{
      schema_version: 1,
      raw_artifact: raw_path,
      event_count: 0,
      event_counts: %{},
      phase_counts: %{},
      correctness: %{},
      observer: observer_aggregate(),
      telemetry: telemetry_aggregate(),
      evidence: %{dropped_events: 0, incomplete?: false}
    }

    raw_path
    |> File.stream!([], :line)
    |> Enum.reduce_while({:ok, initial}, fn line, {:ok, aggregate} ->
      case Jason.decode(String.trim(line)) do
        {:ok, event} -> {:cont, {:ok, aggregate_event(aggregate, event)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, aggregate} ->
        {:ok, put_in(aggregate, [:evidence, :incomplete?], aggregate.evidence.dropped_events > 0)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [File.Error] -> {:error, error}
  end

  @spec checkout_step_events(Result.t()) :: [map()]
  def checkout_step_events(%Result{input: %Input{} = input, artifacts: %{raw: raw_path}})
      when is_binary(raw_path) do
    max_events = max(input.worker_count * 10, 100)

    raw_path
    |> File.stream!([], :line)
    |> Stream.map(&Jason.decode!(String.trim(&1)))
    |> Stream.filter(&(&1["event_type"] == "checkout_step"))
    |> Stream.take(max_events)
    |> Enum.map(&checkout_step_from_event/1)
  end

  def checkout_step_events(_result), do: []

  @spec to_report_map(Result.t()) :: map()
  def to_report_map(%Result{} = result) do
    %{
      schema_version: 1,
      status: result.status,
      lifecycle_state: result.lifecycle_state,
      input: Input.public_map(result.input),
      workload: result.workload,
      correctness: result.correctness,
      observer_summary: result.observer_summary,
      observer: result.observer,
      telemetry: result.telemetry,
      artifacts: result.artifacts,
      errors: result.errors,
      evidence: result.evidence,
      aggregate: result.aggregate
    }
  end

  defp open(%Input{} = input) do
    raw_path = artifact_path(input, "raw.ndjson")
    aggregate_path = artifact_path(input, "aggregate.json")
    final_report_path = artifact_path(input, "report.json")

    case File.mkdir_p(input.artifact_directory) do
      :ok ->
        case File.open(raw_path, [:write, :exclusive, :binary]) do
          {:ok, io} -> open_raw_io(input, raw_path, aggregate_path, final_report_path, io)
          {:error, reason} -> {:error, artifact_open_error(raw_path, reason)}
        end

      {:error, reason} ->
        {:error, artifact_open_error(raw_path, reason)}
    end
  end

  defp open_raw_io(input, raw_path, aggregate_path, final_report_path, io) do
    case new_tables() do
      {:ok, events_table, meta_table} ->
        case write_header(io, input) do
          :ok ->
            case start_writer(io, events_table, meta_table, input) do
              {:ok, writer_pid} ->
                configured = %Session{
                  state: :configured,
                  input: input,
                  raw_path: raw_path,
                  aggregate_path: aggregate_path,
                  final_report_path: final_report_path,
                  events_table: events_table,
                  meta_table: meta_table,
                  writer_pid: writer_pid
                }

                transition_session(configured, :raw_open)

              {:error, reason} ->
                delete_tables(events_table, meta_table)
                safe_close(io)
                {:error, artifact_open_error(raw_path, reason)}
            end

          {:error, reason} ->
            delete_tables(events_table, meta_table)
            safe_close(io)
            {:error, artifact_open_error(raw_path, reason)}
        end

      {:error, reason} ->
        safe_close(io)
        {:error, artifact_open_error(raw_path, reason)}
    end
  end

  defp artifact_open_error(raw_path, reason),
    do: %{
      kind: :artifact,
      code: :raw_artifact_creation_failed,
      reason: safe_reason(reason),
      raw_path: raw_path
    }

  defp execute_run(%Session{} = session, workload_fun, opts) do
    try do
      with {:ok, running} <- transition_session(session, :running) do
        running =
          case ensure_telemetry_started() do
            :ok ->
              running

            {:error, reason} ->
              _ = record_instrumentation_error(running, {:telemetry_start, reason})
              running
          end

        running = attach_telemetry(running)
        {outcome, payload, workload_error} = execute_workload(running, workload_fun)
        running = detach_telemetry(running)
        finished = persist_workload_outcome(running, outcome, payload, workload_error)

        case transition_session(finished, outcome_state(outcome)) do
          {:ok, workload_finished} ->
            finalize_raw(workload_finished, opts)

          {:error, error} ->
            {:error, artifact_result_from_session(finished, :artifact, error, nil)}
        end
      else
        {:error, error} -> {:error, artifact_result_from_session(session, :artifact, error, nil)}
      end
    after
      cleanup_session(session)
    end
  end

  defp execute_workload(session, workload_fun) do
    try do
      case workload_fun.(session) do
        {:error, payload} when is_map(payload) ->
          {:error, payload, %{kind: :workload, code: :workload_returned_error}}

        {:error, reason} ->
          {:error, %{},
           %{kind: :workload, code: :workload_returned_error, reason: safe_reason(reason)}}

        {:ok, payload} when is_map(payload) ->
          {:complete, payload, nil}

        payload when is_map(payload) ->
          {:complete, payload, nil}

        payload ->
          {:complete, %{return_value: safe_value(payload)}, nil}
      end
    rescue
      error ->
        {:error, %{},
         %{kind: :workload, code: :workload_exception, exception: exception_summary(error)}}
    catch
      kind, reason ->
        {:error, %{},
         %{kind: :workload, code: :workload_throw, throw_kind: kind, reason: safe_reason(reason)}}
    end
  end

  defp persist_workload_outcome(session, outcome, payload, workload_error) do
    workload = normalize_workload(payload, session.input)
    correctness = normalize_correctness(payload, workload, session.input)

    _ = record(session, :workload_result, workload_raw_payload(workload))
    _ = record(session, :correctness, correctness)

    session = %{
      session
      | workload: workload,
        correctness: correctness,
        observer_summary: Map.get(payload, :observer_summary)
    }

    if workload_failure?(outcome, workload, correctness) do
      error =
        workload_error ||
          %{
            kind: :workload,
            code: if(outcome == :error, do: :workload_error, else: :correctness_gate_failed)
          }

      _ = record(session, :workload_error, error)
      %{session | errors: [error | session.errors]}
    else
      session
    end
  end

  defp finalize_raw(session, opts) do
    case seal_raw(session) do
      {:ok, raw_sealed} ->
        aggregate_and_report(raw_sealed, opts)

      {:error, failed} ->
        {:error, artifact_result_from_session(failed, :artifact, %{code: :raw_seal_failed}, nil)}
    end
  end

  defp seal_raw(session) do
    stop_result = stop_writer(session)

    if stop_result == :ok and meta_value(session.meta_table, :writer_error, nil) == nil do
      :ets.insert(session.meta_table, {:sealed?, true})
      transition_session(session, :raw_sealed)
    else
      {:error,
       %{session | errors: [%{kind: :artifact, code: :raw_write_failed} | session.errors]}}
    end
  end

  defp aggregate_and_report(session, opts) do
    case transition_session(session, :aggregating) do
      {:ok, aggregating} ->
        {aggregate_status, aggregate, aggregating} = aggregate(aggregating, opts)
        report_session(aggregating, aggregate_status, aggregate, opts)

      {:error, error} ->
        {:error, artifact_result_from_session(session, :artifact, error, nil)}
    end
  end

  defp aggregate(session, opts) do
    aggregator = Keyword.get(opts, :aggregator, &aggregate_raw/1)

    case call_aggregator(aggregator, session.raw_path) do
      {:ok, aggregate} when is_map(aggregate) ->
        case write_json(session.aggregate_path, aggregate) do
          :ok ->
            {:ok, aggregate, %{session | aggregate_path: session.aggregate_path}}

          {:error, reason} ->
            error = %{
              kind: :artifact,
              code: :aggregate_artifact_write_failed,
              reason: safe_reason(reason)
            }

            {:error, nil, %{session | errors: [error | session.errors]}}
        end

      {:error, reason} ->
        error = %{kind: :aggregation, code: :aggregation_failed, reason: safe_reason(reason)}
        {:error, nil, %{session | errors: [error | session.errors]}}

      other ->
        error = %{
          kind: :aggregation,
          code: :invalid_aggregator_result,
          reason: safe_reason(other)
        }

        {:error, nil, %{session | errors: [error | session.errors]}}
    end
  end

  defp report_session(session, aggregate_status, aggregate, opts) do
    next_state = if aggregate_status == :ok, do: :aggregated, else: :aggregation_failed

    with {:ok, aggregated} <- transition_session(session, next_state),
         {:ok, reporting} <- transition_session(aggregated, :reporting) do
      result = build_result(reporting, aggregate_status, aggregate, reporting.final_report_path)
      reporter = Keyword.get(opts, :reporter, &write_default_report/1)

      case call_reporter(reporter, to_report_map(result)) do
        :ok ->
          final_result =
            build_result(reporting, aggregate_status, aggregate, result.artifacts.final_report)

          finalize_result(final_result, aggregate_status, :ok)

        {:ok, report} ->
          final_result = build_result(reporting, aggregate_status, aggregate, report)
          finalize_result(final_result, aggregate_status, :ok)

        {:error, reason} ->
          error = %{
            kind: :artifact,
            code: :final_report_write_failed,
            reason: safe_reason(reason)
          }

          failed = %{reporting | errors: [error | reporting.errors]}
          final_result = build_result(failed, aggregate_status, aggregate, nil)
          finalize_result(final_result, aggregate_status, :error)

        other ->
          error = %{kind: :artifact, code: :invalid_reporter_result, reason: safe_reason(other)}
          failed = %{reporting | errors: [error | reporting.errors]}
          final_result = build_result(failed, aggregate_status, aggregate, nil)
          finalize_result(final_result, aggregate_status, :error)
      end
    else
      {:error, error} ->
        {:error, artifact_result_from_session(session, :artifact, error, aggregate)}
    end
  end

  defp finalize_result(result, aggregate_status, report_status) do
    status = result_status(result, aggregate_status, report_status)

    terminal_state =
      if status == :artifact_error,
        do: :artifact_failed,
        else: if(status == :evidence_incomplete, do: :evidence_incomplete, else: :complete)

    {:ok, terminal_state} = transition_state(:reporting, terminal_state)
    finalized = %{result | status: status, lifecycle_state: terminal_state}

    if status == :ok, do: {:ok, finalized}, else: {:error, finalized}
  end

  defp result_status(result, aggregate_status, report_status) do
    cond do
      report_status == :error ->
        :artifact_error

      Enum.any?(result.errors, &(&1.kind == :artifact)) ->
        :artifact_error

      aggregate_status == :error and Enum.any?(result.errors, &(&1.kind == :aggregation)) ->
        :aggregation_error

      Enum.any?(result.errors, &(&1.kind == :instrumentation)) ->
        :instrumentation_error

      Enum.any?(result.errors, &(&1.kind == :workload)) ->
        :workload_error

      correctness_gate_failed?(result.correctness) ->
        :workload_error

      result.evidence.incomplete? ->
        :evidence_incomplete

      true ->
        :ok
    end
  end

  defp build_result(session, aggregate_status, aggregate, report_path) do
    raw_scan = scan_raw_evidence(session.raw_path)
    errors = unique_errors(session.errors ++ raw_scan.errors ++ instrumentation_errors(session))
    evidence = evidence_summary(session, raw_scan)
    aggregate = if aggregate_status == :ok, do: aggregate, else: nil

    result = %Result{
      status: :ok,
      lifecycle_state: :reporting,
      input: session.input,
      workload: session.workload,
      correctness: session.correctness,
      observer_summary: session.observer_summary,
      observer: Map.get(aggregate || %{}, :observer, observer_aggregate()),
      telemetry: Map.get(aggregate || %{}, :telemetry, telemetry_aggregate()),
      artifacts: %{
        raw: session.raw_path,
        aggregate: if(aggregate_status == :ok, do: session.aggregate_path),
        final_report: report_path
      },
      errors: errors,
      evidence: evidence,
      aggregate: aggregate,
      report: report_path
    }

    %{result | status: result_status(result, aggregate_status, :ok)}
  end

  defp artifact_result(input, error) do
    %Result{
      status: :artifact_error,
      lifecycle_state: :artifact_failed,
      input: input,
      artifacts: %{raw: Map.get(error, :raw_path)},
      errors: [error],
      evidence: %{incomplete?: true}
    }
  end

  defp artifact_result_from_session(session, _kind, error, aggregate) do
    %Result{
      status: :artifact_error,
      lifecycle_state: :artifact_failed,
      input: session.input,
      workload: session.workload,
      correctness: session.correctness,
      observer_summary: session.observer_summary,
      artifacts: %{raw: session.raw_path, aggregate: session.aggregate_path},
      errors:
        unique_errors(
          session.errors ++ instrumentation_errors(session) ++ [normalize_error(error)]
        ),
      evidence: evidence_summary(session, scan_raw_evidence(session.raw_path)),
      aggregate: aggregate
    }
  end

  defp transition_session(%Session{state: state} = session, next) do
    case transition_state(state, next) do
      {:ok, next} -> {:ok, %{session | state: next}}
      {:error, error} -> {:error, error}
    end
  end

  defp attach_telemetry(%Session{} = session) do
    handlers = [
      {handler_id(session, :repo_query), [:store, :repo, :query],
       &__MODULE__.handle_repo_query_event/4},
      {handler_id(session, :checkout_step), [:store, :checkout, :step],
       &__MODULE__.handle_checkout_step_event/4}
    ]

    Enum.reduce(handlers, session, fn {handler_id, event, handler}, current ->
      case safe_attach_telemetry(handler_id, event, handler, %{session: current}) do
        :ok ->
          %{current | handler_ids: [handler_id | current.handler_ids]}

        {:error, reason} ->
          _ = record_instrumentation_error(current, {:telemetry_attach, reason})
          current
      end
    end)
  end

  defp ensure_telemetry_started do
    case Application.ensure_all_started(:telemetry) do
      {:ok, _applications} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_attach_telemetry(handler_id, event, handler, config) do
    :telemetry.attach(handler_id, event, handler, config)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp detach_telemetry(%Session{} = session) do
    Enum.each(session.handler_ids, fn handler_id ->
      _ = :telemetry.detach(handler_id)
    end)

    %{session | handler_ids: []}
  end

  defp handler_id(session, kind),
    do: {__MODULE__, session.input.run_id, kind, make_ref()}

  defp new_tables do
    events_table = :ets.new(:checkout_diagnostic_events, [:ordered_set, :public])
    meta_table = :ets.new(:checkout_diagnostic_meta, [:set, :public])

    :ets.insert(meta_table, [
      {:next_sequence, 0},
      {:observer_sequence, 0},
      {:buffered, 0},
      {:max_observed_buffered, 0},
      {:dropped, 0},
      {:instrumentation_errors, 0},
      {:writer_error, nil},
      {:sealed?, false}
    ])

    {:ok, events_table, meta_table}
  rescue
    error -> {:error, error}
  end

  defp start_writer(io, events_table, meta_table, input) do
    pid =
      spawn(fn ->
        writer_loop(io, events_table, meta_table, input.flush_interval_ms, false)
      end)

    {:ok, pid}
  rescue
    error -> {:error, error}
  end

  defp writer_loop(io, events_table, meta_table, flush_interval_ms, failed?) do
    receive do
      {:flush, caller, ref} ->
        outcome =
          if failed?,
            do: {:error, meta_value(meta_table, :writer_error, :writer_failed)},
            else: flush_events(io, events_table, meta_table)

        send(caller, {:checkout_diagnostic_flush, ref, outcome})

        writer_loop(
          io,
          events_table,
          meta_table,
          flush_interval_ms,
          failed? or match?({:error, _}, outcome)
        )

      {:stop, caller, ref} ->
        outcome =
          if failed?,
            do: {:error, meta_value(meta_table, :writer_error, :writer_failed)},
            else: flush_events(io, events_table, meta_table)

        close_outcome = File.close(io)

        if match?({:error, _}, outcome),
          do: :ets.insert(meta_table, {:writer_error, elem(outcome, 1)})

        if match?({:error, _}, close_outcome),
          do: :ets.insert(meta_table, {:writer_error, elem(close_outcome, 1)})

        send(
          caller,
          {:checkout_diagnostic_stopped, ref, merge_writer_outcomes(outcome, close_outcome)}
        )

      :stop ->
        _ = flush_events(io, events_table, meta_table)
        _ = File.close(io)

      _other ->
        writer_loop(io, events_table, meta_table, flush_interval_ms, failed?)
    after
      flush_interval_ms ->
        outcome =
          if failed?,
            do: {:error, meta_value(meta_table, :writer_error, :writer_failed)},
            else: flush_events(io, events_table, meta_table)

        writer_loop(
          io,
          events_table,
          meta_table,
          flush_interval_ms,
          failed? or match?({:error, _}, outcome)
        )
    end
  end

  defp flush_events(io, events_table, meta_table) do
    events = :ets.tab2list(events_table)
    dropped = take_counter(meta_table, :dropped)

    drop_event =
      if dropped > 0 do
        sequence = :ets.update_counter(meta_table, :next_sequence, {2, 1}, {:next_sequence, 0})

        [
          %{
            sequence: sequence,
            event_type: "evidence_drop",
            captured_at_ms: System.system_time(:millisecond),
            payload: %{dropped_count: dropped}
          }
        ]
      else
        []
      end

    lines =
      (Enum.map(events, fn {_sequence, event} -> event end) ++ drop_event)
      |> Enum.map_join("", fn event -> Jason.encode!(json_safe(event)) <> "\n" end)

    if lines == "" do
      :ok
    else
      case IO.binwrite(io, lines) do
        :ok ->
          Enum.each(events, fn {sequence, _event} -> :ets.delete(events_table, sequence) end)
          :ets.update_counter(meta_table, :buffered, {2, -length(events)}, {:buffered, 0})
          :ok

        {:error, reason} ->
          if dropped > 0,
            do: :ets.update_counter(meta_table, :dropped, {2, dropped}, {:dropped, 0})

          :ets.insert(meta_table, {:writer_error, reason})
          {:error, reason}
      end
    end
  rescue
    error ->
      :ets.insert(meta_table, {:writer_error, error})
      {:error, error}
  end

  defp merge_writer_outcomes(:ok, :ok), do: :ok
  defp merge_writer_outcomes({:error, reason}, _close), do: {:error, reason}
  defp merge_writer_outcomes(_flush, {:error, reason}), do: {:error, reason}

  defp stop_writer(%Session{} = session) do
    ref = make_ref()
    send(session.writer_pid, {:stop, self(), ref})

    receive do
      {:checkout_diagnostic_stopped, ^ref, :ok} -> :ok
      {:checkout_diagnostic_stopped, ^ref, {:error, reason}} -> {:error, reason}
    after
      @writer_timeout_ms -> {:error, :writer_stop_timeout}
    end
  end

  defp insert_event(session, event_type, payload) do
    sequence =
      :ets.update_counter(session.meta_table, :next_sequence, {2, 1}, {:next_sequence, 0})

    buffered = :ets.update_counter(session.meta_table, :buffered, {2, 1}, {:buffered, 0})

    if buffered <= session.input.max_buffered_events do
      event = %{
        sequence: sequence,
        event_type: event_type,
        captured_at_ms: System.system_time(:millisecond),
        payload: payload
      }

      :ets.insert(session.events_table, {sequence, event})
      update_max_observed(session.meta_table, buffered)
      {:ok, sequence}
    else
      :ets.update_counter(session.meta_table, :buffered, {2, -1}, {:buffered, 0})
      :ets.update_counter(session.meta_table, :dropped, {2, 1}, {:dropped, 0})
      {:error, %{kind: :instrumentation, code: :evidence_buffer_overflow}}
    end
  rescue
    error ->
      {:error, %{kind: :instrumentation, code: :event_record_failed, reason: safe_reason(error)}}
  end

  defp update_max_observed(meta_table, buffered) do
    current = meta_value(meta_table, :max_observed_buffered, 0)
    if buffered > current, do: :ets.insert(meta_table, {:max_observed_buffered, buffered})
  end

  defp take_counter(meta_table, key) do
    case :ets.take(meta_table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp meta_value(meta_table, key, default) do
    case :ets.lookup(meta_table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp write_header(io, input) do
    header = %{
      schema_version: 1,
      event_type: "run_metadata",
      captured_at_ms: System.system_time(:millisecond),
      payload: %{
        input: Input.public_map(input),
        observer: %{
          source: "pg_stat_activity",
          state: "active",
          interval_ms: input.observer_interval_ms,
          ecto_pool_ownership_high_water_available?: false
        },
        runtime: %{
          elixir: System.version(),
          otp: System.otp_release(),
          schedulers_online: System.schedulers_online()
        }
      }
    }

    case IO.binwrite(io, Jason.encode!(json_safe(header)) <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp write_json(path, value) do
    case File.write(path, Jason.encode!(json_safe(value)) <> "\n", [:binary, :exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp write_default_report(report) do
    path =
      get_in(report, [:artifacts, :final_report]) || get_in(report, ["artifacts", "final_report"])

    if is_binary(path) do
      write_json(path, report)
    else
      {:error, :missing_final_report_path}
    end
  end

  defp call_aggregator(aggregator, raw_path) when is_function(aggregator, 1) do
    aggregator.(raw_path)
  rescue
    error -> {:error, {:aggregator_exception, safe_reason(error)}}
  catch
    kind, reason -> {:error, {:aggregator_throw, kind, safe_reason(reason)}}
  end

  defp call_aggregator(_aggregator, _raw_path), do: {:error, :invalid_aggregator}

  defp call_reporter(reporter, report) when is_function(reporter, 1) do
    reporter.(report)
  rescue
    error -> {:error, {:reporter_exception, safe_reason(error)}}
  catch
    kind, reason -> {:error, {:reporter_throw, kind, safe_reason(reason)}}
  end

  defp call_reporter(_reporter, _report), do: {:error, :invalid_reporter}

  defp artifact_path(input, suffix) do
    filename = input.run_id |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    Path.join(input.artifact_directory, "#{filename}.#{suffix}")
  end

  defp safe_close(nil), do: :ok
  defp safe_close(io), do: File.close(io)

  defp delete_tables(events_table, meta_table) do
    safe_delete_table(events_table)
    safe_delete_table(meta_table)
  end

  defp safe_delete_table(table) do
    :ets.delete(table)
  rescue
    ArgumentError -> :ok
  end

  defp cleanup_session(%Session{} = session),
    do: delete_tables(session.events_table, session.meta_table)

  defp outcome_state(:complete), do: :workload_complete
  defp outcome_state(:error), do: :workload_failed

  defp workload_failure?(outcome, workload, correctness) do
    outcome == :error or
      correctness_gate_failed?(correctness) or
      workload.unexpected_failures > 0 or workload.db_errors > 0 or workload.deadlocks > 0
  end

  defp correctness_gate_failed?(%{gate: gate}),
    do: gate in [:fail, "fail", :error, "error"]

  defp correctness_gate_failed?(_correctness), do: false

  defp normalize_workload(payload, input) when is_map(payload) do
    workload = Map.get(payload, :workload, payload)
    durations = workload |> Map.get(:durations_ms, []) |> bounded_numbers(input.worker_count)
    errors = workload |> Map.get(:errors, []) |> bounded_errors(input.worker_count)

    %{
      durations_ms: durations,
      errors: errors,
      completed_workers:
        numeric_or_zero(Map.get(workload, :completed_workers, length(durations))),
      successful_workers:
        numeric_or_zero(Map.get(workload, :successful_workers, length(durations))),
      governed_failures: numeric_or_zero(Map.get(workload, :governed_failures, 0)),
      unexpected_failures:
        numeric_or_zero(Map.get(workload, :unexpected_failures, length(errors))),
      db_errors: numeric_or_zero(Map.get(workload, :db_errors, 0)),
      deadlocks: numeric_or_zero(Map.get(workload, :deadlocks, 0))
    }
  end

  defp normalize_workload(_payload, _input) do
    %{
      durations_ms: [],
      errors: [],
      completed_workers: 0,
      successful_workers: 0,
      governed_failures: 0,
      unexpected_failures: 0,
      db_errors: 0,
      deadlocks: 0
    }
  end

  defp normalize_correctness(payload, workload, input) do
    source = if is_map(payload), do: Map.get(payload, :correctness, %{}), else: %{}

    %{
      expected_workers:
        numeric_or_default(Map.get(source, :expected_workers), input.worker_count),
      completed_workers:
        numeric_or_default(Map.get(source, :completed_workers), workload.completed_workers),
      successful_workers:
        numeric_or_default(Map.get(source, :successful_workers), workload.successful_workers),
      governed_failures:
        numeric_or_default(Map.get(source, :governed_failures), workload.governed_failures),
      unexpected_failures:
        numeric_or_default(Map.get(source, :unexpected_failures), workload.unexpected_failures),
      db_errors: numeric_or_default(Map.get(source, :db_errors), workload.db_errors),
      deadlocks: numeric_or_default(Map.get(source, :deadlocks), workload.deadlocks),
      gate: safe_result(Map.get(source, :gate, :unknown))
    }
  end

  defp workload_raw_payload(workload) do
    %{
      durations_ms: workload.durations_ms,
      duration_count: length(workload.durations_ms),
      error_count: length(workload.errors),
      completed_workers: workload.completed_workers,
      successful_workers: workload.successful_workers,
      governed_failures: workload.governed_failures,
      unexpected_failures: workload.unexpected_failures,
      db_errors: workload.db_errors,
      deadlocks: workload.deadlocks
    }
  end

  defp bounded_numbers(values, limit) when is_list(values) do
    values
    |> Enum.take(max(limit, 1) * 2)
    |> Enum.filter(&is_number/1)
  end

  defp bounded_numbers(_values, _limit), do: []

  defp bounded_errors(values, limit) when is_list(values),
    do: Enum.take(values, max(limit, 1)) |> Enum.map(&error_summary/1)

  defp bounded_errors(_values, _limit), do: []

  defp error_summary(%{kind: kind} = error),
    do: Map.put(%{kind: safe_result(kind)}, :code, safe_result(Map.get(error, :code, :unknown)))

  defp error_summary(error) when is_exception(error),
    do: %{kind: :exception, exception: inspect(error.__struct__)}

  defp error_summary(error), do: %{kind: :error, code: safe_result(error)}

  defp observer_payload(sample, sample_sequence) do
    backend_rows = Map.get(sample, :backend_rows, [])

    lock_waiters =
      Enum.count(backend_rows, fn row ->
        Map.get(row, :state) == "active" and Map.get(row, :wait_event_type) == "Lock"
      end)

    %{
      sample_sequence: sample_sequence,
      sample_start_timestamp_ms:
        Map.get(sample, :sample_start_timestamp_ms, Map.get(sample, :timestamp_ms)),
      sample_end_timestamp_ms:
        Map.get(sample, :sample_end_timestamp_ms, Map.get(sample, :timestamp_ms)),
      phase: safe_result(Map.get(sample, :phase, :untracked)),
      total_active_backends:
        numeric_or_zero(
          Map.get(sample, :total_active_backends, Map.get(sample, :active_backends, 0))
        ),
      store_repo_active_backends: numeric_or_zero(Map.get(sample, :repo_active_backends, 0)),
      direct_repo_active_backends:
        numeric_or_zero(Map.get(sample, :direct_repo_active_backends, 0)),
      other_active_backends: numeric_or_zero(Map.get(sample, :other_active_backends, 0)),
      store_repo_utilization:
        numeric_or_zero(
          Map.get(
            sample,
            :repo_active_backend_utilization,
            Map.get(sample, :active_backend_utilization, 0.0)
          )
        ),
      direct_repo_utilization:
        numeric_or_zero(Map.get(sample, :direct_repo_active_backend_utilization, 0.0)),
      lock_wait_classification: %{
        total: numeric_or_default(Map.get(sample, :total_lock_waiters), lock_waiters),
        expected_reservation:
          numeric_or_default(Map.get(sample, :expected_reservation_waiters), 0),
        unexpected: numeric_or_default(Map.get(sample, :unexpected_lock_waiters), lock_waiters)
      },
      postgres: %{backend_rows: Enum.map(backend_rows, &sanitize_backend_row/1)}
    }
  end

  defp sanitize_backend_row(row) when is_map(row) do
    %{
      pid: safe_value(Map.get(row, :pid)),
      application_name: safe_string(Map.get(row, :application_name)),
      state: safe_string(Map.get(row, :state)),
      wait_event_type: safe_string(Map.get(row, :wait_event_type)),
      wait_event: safe_string(Map.get(row, :wait_event)),
      query_identity: query_identity(Map.get(row, :query)),
      has_blocker?: Map.get(row, :has_blocker?, false) == true,
      waits_on_target_row?: Map.get(row, :waits_on_target_row?, false) == true
    }
  end

  defp sanitize_backend_row(_row), do: %{}

  defp summary_without_backend_queries(summary) do
    summary
    |> Map.delete(:backend_rows)
    |> Map.delete("backend_rows")
    |> Map.delete(:query)
    |> Map.delete("query")
  end

  defp query_identity(nil), do: %{command: nil, fingerprint: nil, length: 0}

  defp query_identity(query) when is_binary(query) do
    normalized = query |> String.replace(~r/\s+/, " ") |> String.trim() |> String.downcase()
    command = normalized |> String.split(" ", parts: 2) |> List.first()
    fingerprint = :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
    %{command: command, fingerprint: fingerprint, length: byte_size(normalized)}
  end

  defp query_identity(query), do: query_identity(safe_string(query))

  defp parameter_count(params) when is_list(params), do: length(params)
  defp parameter_count(_params), do: 0

  defp observer_aggregate do
    %{
      metric: %{
        source: "pg_stat_activity",
        state: "active",
        ecto_pool_ownership_high_water_available?: false
      },
      sample_count: 0,
      peak_store_repo_active_backends: nil,
      peak_store_repo_utilization: 0.0,
      peak_sample_sequences: [],
      peak_utilization_sample_sequences: [],
      peak_lock_waiters: 0,
      peak_unexpected_lock_waiters: 0,
      summaries: []
    }
  end

  defp telemetry_aggregate do
    %{
      repo_query_count: 0,
      repo_query_time_ms_total: 0.0,
      repo_queue_time_ms_total: 0.0,
      repo_queue_time_ms_max: 0.0,
      checkout_step_count: 0,
      checkout_steps: %{},
      worker_sync_count: 0,
      inventory_subphases: %{}
    }
  end

  defp aggregate_event(aggregate, %{"event_type" => event_type, "sequence" => sequence} = event) do
    aggregate = %{
      aggregate
      | event_count: aggregate.event_count + 1,
        event_counts: Map.update(aggregate.event_counts, event_type, 1, &(&1 + 1))
    }

    case event_type do
      "correctness" ->
        %{aggregate | correctness: correctness_from_payload(event["payload"] || %{})}

      "observer_sample" ->
        aggregate_observer_sample(aggregate, event["payload"] || %{}, sequence)

      "observer_summary" ->
        aggregate_observer_summary(aggregate, event["payload"] || %{})

      "phase" ->
        aggregate_phase(aggregate, event["payload"] || %{})

      "worker_sync" ->
        aggregate_worker_sync(aggregate)

      "inventory_subphase" ->
        aggregate_inventory_subphase(aggregate, event["payload"] || %{})

      "repo_query" ->
        aggregate_repo_query(aggregate, event["payload"] || %{})

      "checkout_step" ->
        aggregate_checkout_step(aggregate, event["payload"] || %{})

      "evidence_drop" ->
        aggregate_drop(aggregate, event["payload"] || %{})

      "instrumentation_error" ->
        put_in(aggregate, [:evidence, :incomplete?], true)

      _ ->
        aggregate
    end
  end

  defp aggregate_event(aggregate, _event), do: aggregate

  defp aggregate_observer_sample(aggregate, payload, event_sequence) do
    sample_sequence = numeric_or_default(payload["sample_sequence"], event_sequence)
    active = numeric_or_zero(payload["store_repo_active_backends"])
    utilization = numeric_or_zero(payload["store_repo_utilization"])
    observer = aggregate.observer

    observer =
      observer
      |> Map.update!(:sample_count, &(&1 + 1))
      |> peak_update(
        :peak_store_repo_active_backends,
        active,
        sample_sequence,
        :peak_sample_sequences
      )
      |> peak_update(
        :peak_store_repo_utilization,
        utilization,
        sample_sequence,
        :peak_utilization_sample_sequences
      )
      |> Map.put(
        :peak_lock_waiters,
        max(
          observer.peak_lock_waiters,
          get_in(payload, ["lock_wait_classification", "total"]) || 0
        )
      )
      |> Map.put(
        :peak_unexpected_lock_waiters,
        max(
          observer.peak_unexpected_lock_waiters,
          get_in(payload, ["lock_wait_classification", "unexpected"]) || 0
        )
      )

    %{aggregate | observer: observer}
  end

  defp peak_update(observer, value_key, value, sample_sequence, identity_key) do
    current = Map.get(observer, value_key)

    cond do
      is_nil(current) or value > current ->
        observer |> Map.put(value_key, value) |> Map.put(identity_key, [sample_sequence])

      value == current ->
        Map.update!(observer, identity_key, &(&1 ++ [sample_sequence]))

      true ->
        observer
    end
  end

  defp aggregate_observer_summary(aggregate, payload) do
    summaries = aggregate.observer.summaries

    %{
      aggregate
      | observer: Map.put(aggregate.observer, :summaries, Enum.take(summaries ++ [payload], 32))
    }
  end

  defp aggregate_repo_query(aggregate, payload) do
    telemetry = aggregate.telemetry
    query_time = numeric_or_zero(payload["query_time_ms"])
    queue_time = numeric_or_zero(payload["queue_time_ms"])

    %{
      aggregate
      | telemetry: %{
          telemetry
          | repo_query_count: telemetry.repo_query_count + 1,
            repo_query_time_ms_total: telemetry.repo_query_time_ms_total + query_time,
            repo_queue_time_ms_total: telemetry.repo_queue_time_ms_total + queue_time,
            repo_queue_time_ms_max: max(telemetry.repo_queue_time_ms_max, queue_time)
        }
    }
  end

  defp aggregate_phase(aggregate, payload) do
    phase = payload["phase"] || "unknown"
    %{aggregate | phase_counts: Map.update(aggregate.phase_counts, phase, 1, &(&1 + 1))}
  end

  defp aggregate_worker_sync(aggregate) do
    update_in(aggregate, [:telemetry, :worker_sync_count], &(&1 + 1))
  end

  defp aggregate_inventory_subphase(aggregate, payload) do
    subphase = payload["subphase"] || payload["phase"] || "unknown"

    update_in(
      aggregate,
      [:telemetry, :inventory_subphases, subphase],
      &((&1 || 0) + 1)
    )
  end

  defp aggregate_checkout_step(aggregate, payload) do
    telemetry = aggregate.telemetry
    step = payload["step"] || "unknown"

    current =
      Map.get(telemetry.checkout_steps, step, %{
        count: 0,
        duration_ms_total: 0.0,
        query_count_total: 0
      })

    step_summary = %{
      current
      | count: current.count + 1,
        duration_ms_total: current.duration_ms_total + numeric_or_zero(payload["duration_ms"]),
        query_count_total: current.query_count_total + numeric_or_zero(payload["query_count"])
    }

    %{
      aggregate
      | telemetry: %{
          telemetry
          | checkout_step_count: telemetry.checkout_step_count + 1,
            checkout_steps: Map.put(telemetry.checkout_steps, step, step_summary)
        }
    }
  end

  defp aggregate_drop(aggregate, payload) do
    dropped = numeric_or_zero(payload["dropped_count"])
    put_in(aggregate, [:evidence, :dropped_events], aggregate.evidence.dropped_events + dropped)
  end

  defp correctness_from_payload(payload) do
    Enum.into(payload, %{}, fn {key, value} -> {known_key(key), value} end)
  end

  defp known_key("expected_workers"), do: :expected_workers
  defp known_key("completed_workers"), do: :completed_workers
  defp known_key("successful_workers"), do: :successful_workers
  defp known_key("governed_failures"), do: :governed_failures
  defp known_key("unexpected_failures"), do: :unexpected_failures
  defp known_key("db_errors"), do: :db_errors
  defp known_key("deadlocks"), do: :deadlocks
  defp known_key("gate"), do: :gate
  defp known_key(key), do: key

  defp checkout_step_from_event(event) do
    payload = event["payload"] || %{}

    %{
      step: payload["step"],
      result: string_to_result(payload["result"]),
      duration_ms: numeric_or_zero(payload["duration_ms"]),
      query_count: numeric_or_zero(payload["query_count"]),
      queue_time_ms: numeric_or_zero(payload["queue_time_ms"]),
      query_time_ms: numeric_or_zero(payload["query_time_ms"]),
      decode_time_ms: numeric_or_zero(payload["decode_time_ms"])
    }
  end

  defp string_to_result("ok"), do: :ok
  defp string_to_result("duplicate"), do: :duplicate
  defp string_to_result(result), do: result

  defp evidence_summary(session, scan) do
    %{
      raw_event_count: scan.raw_event_count,
      dropped_events: scan.dropped_events,
      incomplete?:
        scan.raw_read_error? or scan.dropped_events > 0 or
          meta_value(session.meta_table, :instrumentation_errors, 0) > 0,
      max_buffered_events: session.input.max_buffered_events,
      max_observed_buffered_events: meta_value(session.meta_table, :max_observed_buffered, 0)
    }
  end

  defp unique_errors(errors) do
    errors
    |> Enum.map(&normalize_error/1)
    |> Enum.uniq_by(&{&1.kind, &1.code})
  end

  defp instrumentation_errors(session) do
    if meta_value(session.meta_table, :instrumentation_errors, 0) > 0 do
      [%{kind: :instrumentation, code: :instrumentation_error_recorded}]
    else
      []
    end
  end

  defp normalize_error(%{kind: kind} = error) when is_atom(kind), do: error

  defp normalize_error(%{kind: kind} = error) when is_binary(kind),
    do: Map.put(error, :kind, string_to_atom(kind))

  defp normalize_error(%{code: _code} = error), do: Map.put_new(error, :kind, :artifact)

  defp normalize_error(error), do: %{kind: :artifact, code: safe_result(error)}

  defp scan_raw_evidence(path) when is_binary(path) do
    initial = %{
      raw_event_count: 0,
      dropped_events: 0,
      errors: [],
      raw_read_error?: false
    }

    try do
      path
      |> File.stream!([], :line)
      |> Enum.reduce(initial, fn line, scan ->
        case Jason.decode(String.trim(line)) do
          {:ok, event} -> scan_raw_event(scan, event)
          {:error, _reason} -> %{scan | raw_read_error?: true}
        end
      end)
    rescue
      _error -> %{initial | raw_read_error?: true}
    end
  end

  defp scan_raw_evidence(_path),
    do: %{raw_event_count: 0, dropped_events: 0, errors: [], raw_read_error?: true}

  defp scan_raw_event(scan, %{"event_type" => "evidence_drop", "payload" => payload}) do
    %{
      scan
      | raw_event_count: scan.raw_event_count + 1,
        dropped_events: scan.dropped_events + numeric_or_zero(payload["dropped_count"])
    }
  end

  defp scan_raw_event(scan, %{"event_type" => "workload_error", "payload" => payload}) do
    error = %{kind: :workload, code: string_to_atom(payload["code"])}
    %{scan | raw_event_count: scan.raw_event_count + 1, errors: [error | scan.errors]}
  end

  defp scan_raw_event(scan, %{"event_type" => "instrumentation_error", "payload" => payload}) do
    error = %{kind: :instrumentation, code: string_to_atom(payload["code"])}
    %{scan | raw_event_count: scan.raw_event_count + 1, errors: [error | scan.errors]}
  end

  defp scan_raw_event(scan, _event), do: %{scan | raw_event_count: scan.raw_event_count + 1}

  defp exception_summary(error) do
    %{module: inspect(error.__struct__), kind: :exception}
  end

  defp error_code({kind, reason}), do: "#{safe_result(kind)}:#{safe_result(reason)}"
  defp error_code(reason), do: safe_result(reason)

  defp safe_reason(%{__struct__: module}), do: inspect(module)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: "[REDACTED]"
  defp safe_reason(_reason), do: "redacted"

  defp safe_result(value) when is_nil(value) or is_boolean(value), do: value
  defp safe_result(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_result(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp safe_result(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_result(value), do: safe_reason(value)

  defp safe_string(nil), do: nil
  defp safe_string(value) when is_binary(value), do: String.slice(value, 0, 160)
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value), do: safe_result(value)

  defp numeric_or_zero(value) when is_number(value), do: value
  defp numeric_or_zero(_value), do: 0

  defp numeric_or_default(value, _default) when is_number(value), do: value
  defp numeric_or_default(_value, default), do: default

  defp native_to_ms(value) when is_number(value),
    do: System.convert_time_unit(trunc(value), :native, :microsecond) / 1_000

  defp native_to_ms(_value), do: 0.0

  defp string_to_atom(value) when is_binary(value) do
    case value do
      "workload_exception" -> :workload_exception
      "workload_returned_error" -> :workload_returned_error
      "workload_throw" -> :workload_throw
      "evidence_buffer_overflow" -> :evidence_buffer_overflow
      _ -> :recorded_error
    end
  end

  defp string_to_atom(value), do: value

  defp json_safe(%_struct{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = to_string(key)

      value =
        if sensitive_key?(key) do
          "[REDACTED]"
        else
          json_safe(value)
        end

      {key, value}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_nil(value) or is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp json_safe(value), do: value

  defp sensitive_key?(key) do
    key = String.downcase(key)

    MapSet.member?(@sensitive_keys, key) or
      String.contains?(key, "secret") or
      String.starts_with?(key, "bind") or
      String.ends_with?(key, "_token") or
      String.ends_with?(key, "_password")
  end

  defp safe_value(value)
       when is_number(value) or is_binary(value) or is_boolean(value) or is_nil(value), do: value

  defp safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_value(value), do: safe_reason(value)
end
