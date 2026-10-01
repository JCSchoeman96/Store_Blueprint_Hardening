defmodule Store.Orders.InventoryAdmission.Reference do
  @moduledoc false

  @enforce_keys [
    :reservation_key,
    :variant_id,
    :identity_digest,
    :request_fingerprint,
    :member,
    :operation_id,
    :operation_epoch
  ]
  defstruct [
    :reservation_key,
    :variant_id,
    :identity_digest,
    :request_fingerprint,
    :member,
    :operation_id,
    :operation_epoch
  ]

  @type t :: %__MODULE__{
          reservation_key: String.t(),
          variant_id: Ecto.UUID.t(),
          identity_digest: String.t(),
          request_fingerprint: String.t(),
          member: String.t(),
          operation_id: Ecto.UUID.t(),
          operation_epoch: pos_integer()
        }

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = reference) do
    [
      non_empty_binary?(reference.reservation_key),
      non_empty_binary?(reference.variant_id),
      fixed_binary?(reference.identity_digest, 64),
      fixed_binary?(reference.request_fingerprint, 64),
      fixed_binary?(reference.member, 64),
      non_empty_binary?(reference.operation_id),
      is_integer(reference.operation_epoch) and reference.operation_epoch > 0
    ]
    |> Enum.all?()
  end

  def valid?(_reference), do: false

  defp non_empty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp fixed_binary?(value, size), do: is_binary(value) and byte_size(value) == size
end

defmodule Store.Orders.InventoryAdmission do
  @moduledoc """
  Inventory admission lifecycle and bounded Redis orchestration for one inventory
  mutation.

  Redis coordinates admission only. This module never performs durable inventory
  work or accesses PostgreSQL.
  """

  alias Store.Orders.InventoryAdmission.{Lease, Operation, Redis, Reference, Request}
  alias Store.Support.Errors.Error

  @k_v 1

  @states [
    :requested,
    :queued,
    :admitted,
    :reserving,
    :unknown_db_outcome,
    :recovering,
    :unresolved,
    :completed,
    :rejected,
    :expired,
    :abandoned
  ]

  @terminal_states [:completed, :rejected, :expired, :abandoned, :unresolved]
  @live_states @states -- @terminal_states
  @blocked_states [:queued, :admitted, :reserving, :unknown_db_outcome, :recovering, :unresolved]

  @transitions %{
    requested: [:queued, :admitted],
    queued: [:admitted, :expired, :abandoned],
    admitted: [:reserving, :expired],
    reserving: [:completed, :rejected, :unknown_db_outcome],
    unknown_db_outcome: [:recovering],
    recovering: [:completed, :rejected, :unresolved]
  }

  @type state ::
          :requested
          | :queued
          | :admitted
          | :reserving
          | :unknown_db_outcome
          | :recovering
          | :unresolved
          | :completed
          | :rejected
          | :expired
          | :abandoned

  @type guard_evidence ::
          Request.t()
          | :admission_granted
          | :queue_deadline_elapsed
          | :trusted_pre_reservation_abandonment
          | {:operation_and_lease, Operation.t(), Lease.t()}
          | :unclaimed_admitted_lease_expired
          | :known_commit
          | :known_rollback
          | :ambiguous_db_outcome
          | :recovery_ownership_claimed
          | :post_match
          | :pre_match
          | :neither_match

  @type replay_decision ::
          :join_existing_operation
          | :mismatch_no_second_operation
          | :fail_closed
          | :return_existing_outcome
          | :return_existing_terminal
          | :requires_new_authorization

  @type state_list :: [state()]
  @type terminal_state_list :: [state()]

  @type transition_error :: :invalid_admission_state | :invalid_admission_transition

  @type transition_guard_error ::
          transition_error()
          | :invalid_request_guard
          | :invalid_operation_or_lease_guard
          | :invalid_transition_guard

  @spec states() :: state_list()
  def states, do: Enum.map(@states, & &1)

  @spec terminal_states() :: terminal_state_list()
  def terminal_states, do: Enum.map(@terminal_states, & &1)

  @spec terminal?(term()) :: boolean()
  def terminal?(state), do: state in @terminal_states

  @spec live?(term()) :: boolean()
  def live?(state), do: state in @live_states

  @spec blocks_new_operation?(term()) :: boolean()
  def blocks_new_operation?(state), do: state in @blocked_states

  @spec valid_state?(term()) :: boolean()
  def valid_state?(state), do: state in @states

  @spec valid_transition?(term(), term()) :: boolean()
  def valid_transition?(from, to) do
    valid_state?(from) and valid_state?(to) and to in Map.get(@transitions, from, [])
  end

  @spec validate_transition(term(), term()) :: :ok | {:error, transition_error()}
  def validate_transition(from, to) do
    cond do
      not valid_state?(from) or not valid_state?(to) ->
        {:error, :invalid_admission_state}

      valid_transition?(from, to) ->
        :ok

      true ->
        {:error, :invalid_admission_transition}
    end
  end

  @spec validate_transition(term(), term(), guard_evidence()) ::
          :ok | {:error, transition_guard_error()}
  def validate_transition(from, to, evidence) do
    with :ok <- validate_transition(from, to) do
      validate_guard(from, to, evidence)
    end
  end

  @spec classify_replay(state(), Operation.t(), Request.t()) ::
          replay_decision() | {:error, atom()}
  def classify_replay(state, %Operation{} = operation, %Request{} = request) do
    cond do
      not valid_state?(state) ->
        {:error, :invalid_admission_state}

      not Operation.valid?(operation) ->
        {:error, :invalid_operation}

      not Request.valid?(request) ->
        {:error, :invalid_request}

      true ->
        classify_replay_state(state, operation, request)
    end
  end

  def classify_replay(_state, _operation, _request), do: {:error, :invalid_replay_input}

  @spec replay(state(), Operation.t(), Request.t()) :: replay_decision() | {:error, atom()}
  def replay(state, operation, request), do: classify_replay(state, operation, request)

  @spec k_v() :: 1
  def k_v, do: @k_v

  @spec variant_permit_count() :: 1
  def variant_permit_count, do: @k_v

  @spec reserve(map() | Request.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def reserve(input, opts \\ [])

  def reserve(input, opts) when is_list(opts) do
    with {:ok, request} <- trusted_request(input),
         {:ok, redis_result} <- Redis.enqueue_or_return_existing(request, opts),
         result <- map_reserve_result(redis_result, request) do
      result
    else
      {:error, :unavailable} -> {:error, unavailable_error()}
      {:error, :invalid_input} -> {:error, validation_error(:invalid_options)}
      {:error, {:invalid_request, reason}} -> {:error, validation_error(reason)}
    end
  rescue
    _error -> {:error, unavailable_error()}
  end

  def reserve(_input, _opts), do: {:error, validation_error(:invalid_options)}

  @spec status(Reference.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def status(reference, opts \\ [])

  def status(%Reference{} = reference, opts) when is_list(opts) do
    with :ok <- validate_reference(reference),
         {:ok, redis_result} <- Redis.status(reference, opts) do
      case redis_result do
        {:status, status} -> {:ok, Map.put(status, :reference, reference)}
        :mismatch -> {:error, mismatch_error()}
        :frozen -> {:error, unavailable_error()}
      end
    else
      {:error, :unavailable} -> {:error, unavailable_error()}
      {:error, :invalid_input} -> {:error, validation_error(:invalid_reference)}
      {:error, :invalid_reference} -> {:error, validation_error(:invalid_reference)}
    end
  rescue
    _error -> {:error, unavailable_error()}
  end

  def status(_reference, _opts), do: {:error, validation_error(:invalid_reference)}

  @spec abandon(Reference.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def abandon(reference, opts \\ [])

  def abandon(%Reference{} = reference, opts) when is_list(opts) do
    with :ok <- validate_reference(reference),
         {:ok, redis_result} <-
           Redis.abandon(reference, :trusted_pre_reservation_abandonment, opts) do
      case redis_result do
        {:abandoned, result} -> {:ok, Map.put(result, :reference, reference)}
        {:already_abandoned, result} -> {:ok, Map.put(result, :reference, reference)}
        :mismatch -> {:error, mismatch_error()}
        :frozen -> {:error, unsupported_error()}
      end
    else
      {:error, :unavailable} -> {:error, unavailable_error()}
      {:error, :invalid_input} -> {:error, validation_error(:invalid_reference)}
      {:error, :invalid_reference} -> {:error, validation_error(:invalid_reference)}
    end
  rescue
    _error -> {:error, unavailable_error()}
  end

  def abandon(_reference, _opts), do: {:error, validation_error(:invalid_reference)}

  defp trusted_request(%Request{} = request) do
    case Request.new(request) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, {:invalid_request, reason}}
    end
  end

  defp trusted_request(params) when is_map(params) do
    case Request.new(params) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, {:invalid_request, reason}}
    end
  end

  defp trusted_request(_input), do: {:error, {:invalid_request, :invalid_request}}

  defp map_reserve_result({kind, admission}, request)
       when kind in [:existing, :queued, :admitted] and is_map(admission) do
    {:ok, Map.put(admission, :reference, reference_from(request, admission))}
  end

  defp map_reserve_result(:busy, _request),
    do: {:error, admission_error("INVENTORY_ADMISSION_BUSY", "inventory admission is busy")}

  defp map_reserve_result(:mismatch, _request), do: {:error, mismatch_error()}
  defp map_reserve_result(:frozen, _request), do: {:error, unavailable_error()}
  defp map_reserve_result(_result, _request), do: {:error, unavailable_error()}

  defp reference_from(request, admission) do
    %Reference{
      reservation_key: request.reservation_key,
      variant_id: request.variant_id,
      identity_digest: request.identity_digest,
      request_fingerprint: request.request_fingerprint,
      member: admission.member,
      operation_id: admission.operation_id,
      operation_epoch: admission.operation_epoch
    }
  end

  defp validate_reference(%Reference{} = reference) do
    if Reference.valid?(reference) do
      :ok
    else
      {:error, :invalid_reference}
    end
  end

  defp admission_error(code, message), do: Error.new(code, message)

  defp unavailable_error,
    do: admission_error("INVENTORY_ADMISSION_UNAVAILABLE", "inventory admission is unavailable")

  defp unsupported_error,
    do:
      admission_error(
        "INVENTORY_ADMISSION_UNSUPPORTED",
        "inventory admission operation is unsupported"
      )

  defp mismatch_error,
    do:
      admission_error(
        "IDEMPOTENCY_KEY_REUSE_MISMATCH",
        "request fingerprint does not match the live operation"
      )

  defp validation_error(reason),
    do: Error.new("VALIDATION_ERROR", "inventory admission input is invalid", %{reason: reason})

  defp validate_guard(:requested, to, %Request{} = request) when to in [:queued, :admitted] do
    if Request.valid?(request), do: :ok, else: {:error, :invalid_request_guard}
  end

  defp validate_guard(:queued, :admitted, :admission_granted), do: :ok

  defp validate_guard(:queued, :expired, :queue_deadline_elapsed), do: :ok

  defp validate_guard(:queued, :abandoned, :trusted_pre_reservation_abandonment), do: :ok

  defp validate_guard(
         :admitted,
         :reserving,
         {:operation_and_lease, %Operation{} = operation, %Lease{} = lease}
       ) do
    if Operation.valid?(operation) and Lease.valid?(lease) and
         matching_operation_lease?(operation, lease) do
      :ok
    else
      {:error, :invalid_operation_or_lease_guard}
    end
  end

  defp validate_guard(:admitted, :expired, :unclaimed_admitted_lease_expired), do: :ok
  defp validate_guard(:reserving, :completed, :known_commit), do: :ok
  defp validate_guard(:reserving, :rejected, :known_rollback), do: :ok
  defp validate_guard(:reserving, :unknown_db_outcome, :ambiguous_db_outcome), do: :ok
  defp validate_guard(:unknown_db_outcome, :recovering, :recovery_ownership_claimed), do: :ok
  defp validate_guard(:recovering, :completed, :post_match), do: :ok
  defp validate_guard(:recovering, :rejected, :pre_match), do: :ok
  defp validate_guard(:recovering, :unresolved, :neither_match), do: :ok
  defp validate_guard(_from, _to, _evidence), do: {:error, :invalid_transition_guard}

  defp matching_operation_lease?(operation, lease) do
    mutation = operation.mutation
    deadline = operation.deadline

    mutation.variant_id == lease.variant_id and
      operation.identity_digest == lease.identity_digest and
      deadline.db_deadline == lease.db_deadline and
      deadline.lease_deadline == lease.lease_deadline and
      deadline.safety_margin == lease.safety_margin
  end

  defp live_replay_decision(operation, request) do
    if operation.request_fingerprint == request.request_fingerprint do
      :join_existing_operation
    else
      :mismatch_no_second_operation
    end
  end

  defp classify_replay_state(_state, operation, request)
       when operation.reservation_key != request.reservation_key,
       do: :mismatch_no_second_operation

  defp classify_replay_state(:unresolved, _operation, _request), do: :fail_closed

  defp classify_replay_state(state, operation, request) when state in @live_states,
    do: live_replay_decision(operation, request)

  defp classify_replay_state(:completed, operation, request) do
    if operation.request_fingerprint == request.request_fingerprint do
      :return_existing_outcome
    else
      :requires_new_authorization
    end
  end

  defp classify_replay_state(state, operation, request)
       when state in [:rejected, :expired, :abandoned] do
    if operation.request_fingerprint == request.request_fingerprint do
      :return_existing_terminal
    else
      :requires_new_authorization
    end
  end
end
