defmodule Store.Orders.InventoryAdmission do
  @moduledoc """
  Pure admission lifecycle and replay contract for one inventory mutation.

  This module owns admission states and legal transitions. It does not perform
  admission, coordinate capacity, or access Redis or PostgreSQL.
  """

  alias Store.Orders.InventoryAdmission.{Lease, Operation, Request}

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

  @spec states() :: [state()]
  def states, do: @states

  @spec terminal_states() :: [state()]
  def terminal_states, do: @terminal_states

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

  @spec validate_transition(term(), term()) :: :ok | {:error, atom()}
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

  @spec validate_transition(term(), term(), guard_evidence()) :: :ok | {:error, atom()}
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
      operation.request_fingerprint == lease.identity_digest and
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
