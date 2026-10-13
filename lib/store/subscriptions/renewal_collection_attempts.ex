defmodule Store.Subscriptions.RenewalCollectionAttempts do
  @moduledoc """
  Starts and replays durable payment collections within one bound renewal.
  """

  import Ecto.Query
  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.Variant
  alias Store.Orders.InventoryAdmission.Request
  alias Store.Orders.{InventoryReservation, Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Payments.Providers
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    AttachAndClaimInput,
    CancellationReservationInput,
    ClaimDispatchInput,
    FenceInput,
    PaymentApplicationSettlementInput,
    PaymentIntentBindingInput,
    RecordFinancialOutcomeInput,
    ReservationGenerationInput,
    ResumeInput,
    StartInput
  }

  alias Store.Support.ID.UUIDv7

  alias Store.Subscriptions.{
    RenewalAttempt,
    RenewalCollectionAttempt,
    Subscription
  }

  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}

  @renewal_authority_withdrawn_code "RENEWAL_AUTHORITY_WITHDRAWN"

  @spec start_for_system(StartInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def start_for_system(%StartInput{} = input) do
    with {:ok, canonical_input} <- StartInput.new(Map.from_struct(input)),
         {:ok, attempt} <- fetch_renewal_attempt(canonical_input.renewal_attempt_id) do
      start_locked(attempt, canonical_input)
    end
  end

  def start_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed renewal collection input is required")}
  end

  @spec start_and_assign_for_system(StartInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def start_and_assign_for_system(%StartInput{} = input) do
    with {:ok, canonical_input} <- StartInput.new(Map.from_struct(input)),
         {:ok, subscription_id} <- start_input_subscription_id(canonical_input) do
      start_and_assign_locked(subscription_id, canonical_input)
    end
  end

  def start_and_assign_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed renewal collection input is required")}
  end

  @spec payment_intent_key(String.t()) :: String.t()
  def payment_intent_key(collection_attempt_id) when is_binary(collection_attempt_id),
    do: "renewal-collection:" <> collection_attempt_id

  @spec attach_payment_intent_for_system(PaymentIntentBindingInput.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def attach_payment_intent_for_system(%PaymentIntentBindingInput{} = input) do
    with {:ok, canonical_input} <- PaymentIntentBindingInput.new(Map.from_struct(input)),
         {:ok, collection,
          %{renewal_attempt: attempt, order: order, payment_intent: payment_intent}} <-
           run_collection_transition_with_result(
             canonical_input.collection_attempt_id,
             :attach_renewal_collection_payment_intent,
             fn collection, attempt, subscription ->
               attach_payment_intent_locked(collection, attempt, subscription, canonical_input)
             end
           ) do
      {:ok,
       %{
         collection_attempt: collection,
         renewal_attempt: attempt,
         order: order,
         payment_intent: payment_intent
       }}
    end
  end

  def attach_payment_intent_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection PaymentIntent binding is required")}
  end

  @spec claim_dispatch_for_system(ClaimDispatchInput.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def claim_dispatch_for_system(%ClaimDispatchInput{} = input) do
    with {:ok, canonical_input} <- ClaimDispatchInput.new(Map.from_struct(input)),
         {:ok, collection,
          %{
            subscription: subscription,
            renewal_attempt: attempt,
            order: order,
            payment_intent: payment_intent,
            provider_payment_method: provider_payment_method
          }} <-
           run_collection_transition_with_result(
             canonical_input.collection_attempt_id,
             :claim_renewal_collection_dispatch,
             fn collection, attempt, subscription ->
               claim_dispatch_locked(collection, attempt, subscription, canonical_input)
             end
           ) do
      {:ok,
       %{
         subscription: subscription,
         collection_attempt: collection,
         renewal_attempt: attempt,
         order: order,
         payment_intent: payment_intent,
         provider_payment_method: provider_payment_method
       }}
    end
  end

  def claim_dispatch_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection dispatch input is required")}
  end

  @spec attach_and_claim_dispatch_for_system(AttachAndClaimInput.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def attach_and_claim_dispatch_for_system(%AttachAndClaimInput{} = input) do
    with {:ok, canonical_input} <- AttachAndClaimInput.new(Map.from_struct(input)),
         {:ok, collection, result} <-
           run_collection_transition_with_expected_identity(
             canonical_input.collection_attempt_id,
             %{
               renewal_attempt_id: canonical_input.renewal_attempt_id,
               subscription_id: canonical_input.subscription_id
             },
             :attach_and_claim_renewal_collection_dispatch,
             fn collection, attempt, subscription ->
               attach_and_claim_dispatch_locked(
                 collection,
                 attempt,
                 subscription,
                 canonical_input
               )
             end
           ) do
      {:ok, Map.put(result, :collection_attempt, collection)}
    end
  end

  def attach_and_claim_dispatch_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection attach and claim input is required")}
  end

  @spec replay_dispatch_for_system(ClaimDispatchInput.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def replay_dispatch_for_system(%ClaimDispatchInput{} = input) do
    with {:ok, canonical_input} <- ClaimDispatchInput.new(Map.from_struct(input)),
         {:ok, collection,
          %{
            subscription: subscription,
            renewal_attempt: attempt,
            order: order,
            payment_intent: payment_intent,
            provider_payment_method: provider_payment_method
          }} <-
           run_collection_transition_with_result(
             canonical_input.collection_attempt_id,
             :replay_renewal_collection_dispatch,
             fn collection, attempt, subscription ->
               replay_dispatch_locked(collection, attempt, subscription, canonical_input)
             end
           ) do
      {:ok,
       %{
         subscription: subscription,
         collection_attempt: collection,
         renewal_attempt: attempt,
         order: order,
         payment_intent: payment_intent,
         provider_payment_method: provider_payment_method
       }}
    end
  end

  def replay_dispatch_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection dispatch input is required")}
  end

  @spec recover_reached_for_subscription_for_system(String.t(), DateTime.t()) ::
          {:ok, map() | nil} | {:error, Error.t() | term()}
  def recover_reached_for_subscription_for_system(subscription_id, now)
      when is_binary(subscription_id) and is_struct(now, DateTime) do
    query = """
    SELECT collection.id::text, collection.dispatch_epoch
    FROM renewal_collection_attempts AS collection
    JOIN renewal_attempts AS attempt
      ON attempt.id = collection.renewal_attempt_id
    WHERE attempt.subscription_id = $1::text::uuid
      AND collection.dispatch_state = 'may_have_been_reached'
      AND collection.financial_outcome IN ('unresolved', 'requires_action')
    LIMIT 2
    """

    case Repo.query(query, [subscription_id]) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[collection_attempt_id, expected_epoch]]}} ->
        with {:ok, input} <-
               ClaimDispatchInput.new(%{
                 collection_attempt_id: collection_attempt_id,
                 expected_epoch: expected_epoch,
                 now: now
               }) do
          replay_dispatch_for_system(input)
        end

      {:ok, %{rows: [_first, _second | _rest]}} ->
        {:error,
         Error.new(
           "PAYMENT_OUTCOME_UNRESOLVED",
           "multiple reached renewal collections require exact reconciliation"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def recover_reached_for_subscription_for_system(_subscription_id, _now) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "subscription_id and current time are required to recover a reached collection"
     )}
  end

  @spec record_financial_outcome_for_system(RecordFinancialOutcomeInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def record_financial_outcome_for_system(%RecordFinancialOutcomeInput{} = input) do
    with {:ok, canonical_input} <- RecordFinancialOutcomeInput.new(Map.from_struct(input)) do
      transition = fn collection, _attempt, _subscription ->
        record_financial_outcome_locked(collection, canonical_input)
      end

      case {canonical_input.renewal_attempt_id, canonical_input.subscription_id} do
        {renewal_attempt_id, subscription_id}
        when is_binary(renewal_attempt_id) and is_binary(subscription_id) ->
          run_collection_transition_with_identity(
            canonical_input.collection_attempt_id,
            %{
              renewal_attempt_id: renewal_attempt_id,
              subscription_id: subscription_id
            },
            :record_renewal_collection_financial_outcome,
            transition,
            false
          )

        _ ->
          run_collection_transition(
            canonical_input.collection_attempt_id,
            :record_renewal_collection_financial_outcome,
            transition
          )
      end
    end
  end

  def record_financial_outcome_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection financial outcome is required")}
  end

  @spec success_handoff_for_system(String.t()) :: {:ok, map()} | {:error, Error.t() | term()}
  def success_handoff_for_system(collection_attempt_id) when is_binary(collection_attempt_id) do
    case success_handoff_context_for_system(collection_attempt_id) do
      {:ok, %{handoff: handoff}} -> {:ok, handoff}
      {:error, reason} -> {:error, reason}
    end
  end

  def success_handoff_for_system(_collection_attempt_id) do
    {:error, Error.new("VALIDATION_ERROR", "collection_attempt_id must be a UUID")}
  end

  @spec success_handoff_context_for_system(String.t()) ::
          {:ok, %{handoff: map(), reconciliation: atom()}} | {:error, Error.t() | term()}
  def success_handoff_context_for_system(collection_attempt_id)
      when is_binary(collection_attempt_id) do
    query = """
    SELECT
      order_row.id::text,
      attempt.id::text,
      collection.id::text,
      payment_intent.id::text,
      attempt.failure_code,
      subscription.status::text
    FROM renewal_collection_attempts AS collection
    JOIN renewal_attempts AS attempt
      ON attempt.id = collection.renewal_attempt_id
    JOIN subscriptions AS subscription
      ON subscription.id = attempt.subscription_id
    JOIN orders AS order_row
      ON order_row.id = attempt.order_id
    JOIN payment_intents AS payment_intent
      ON payment_intent.id = collection.payment_intent_id
     AND payment_intent.order_id = order_row.id
     AND payment_intent.state = 'succeeded'
    WHERE collection.id = $1::text::uuid
      AND collection.financial_outcome = 'verified_success'
    LIMIT 1
    """

    case Repo.query(query, [collection_attempt_id]) do
      {:ok,
       %{
         rows: [
           [order_id, renewal_attempt_id, collection_id, payment_intent_id, failure_code, status]
         ]
       }} ->
        reconciliation =
          if failure_code == @renewal_authority_withdrawn_code or status == "suspended" do
            :recovery_required
          else
            :handoff_only
          end

        {:ok,
         %{
           handoff: %{
             order_id: order_id,
             renewal_attempt_id: renewal_attempt_id,
             collection_attempt_id: collection_id,
             payment_intent_id: payment_intent_id
           },
           reconciliation: reconciliation
         }}

      {:ok, %{rows: []}} ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "verified collection success identity conflicts"
         )}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def success_handoff_context_for_system(_collection_attempt_id) do
    {:error, Error.new("VALIDATION_ERROR", "collection_attempt_id must be a UUID")}
  end

  @spec settle_successful_collection_reservation_for_payment_application(
          PaymentApplicationSettlementInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def settle_successful_collection_reservation_for_payment_application(
        %PaymentApplicationSettlementInput{} = input
      ) do
    with {:ok, canonical_input} <- PaymentApplicationSettlementInput.new(Map.from_struct(input)),
         :ok <- ensure_caller_transaction(),
         {:ok, collection, attempt} <- payment_application_settlement_identity(canonical_input),
         false <- attempt.failure_code == @renewal_authority_withdrawn_code,
         {:ok, physical?} <- physical_renewal?(attempt.variant_id),
         {:ok, result} <-
           settle_collection_reservation(
             collection,
             attempt,
             physical?,
             :consume
           ) do
      {:ok, result}
    else
      true ->
        {:error,
         Error.new(
           "RENEWAL_AUTHORITY_WITHDRAWN",
           "withdrawn renewal collection cannot consume inventory"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def settle_successful_collection_reservation_for_payment_application(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection settlement identity is required")}
  end

  @spec release_withdrawn_collection_reservation_for_payment_application(
          PaymentApplicationSettlementInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def release_withdrawn_collection_reservation_for_payment_application(
        %PaymentApplicationSettlementInput{} = input
      ) do
    with {:ok, canonical_input} <- PaymentApplicationSettlementInput.new(Map.from_struct(input)),
         :ok <- ensure_caller_transaction(),
         {:ok, collection, attempt} <- payment_application_settlement_identity(canonical_input),
         true <- attempt.failure_code == @renewal_authority_withdrawn_code,
         {:ok, physical?} <- physical_renewal?(attempt.variant_id),
         {:ok, result} <-
           settle_collection_reservation(
             collection,
             attempt,
             physical?,
             :release
           ) do
      {:ok, result}
    else
      false ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "renewal authority is not withdrawn")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def release_withdrawn_collection_reservation_for_payment_application(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection settlement identity is required")}
  end

  @spec release_terminal_collection_reservation_for_payment_application(
          PaymentApplicationSettlementInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def release_terminal_collection_reservation_for_payment_application(
        %PaymentApplicationSettlementInput{} = input
      ) do
    with {:ok, canonical_input} <- PaymentApplicationSettlementInput.new(Map.from_struct(input)),
         :ok <- ensure_caller_transaction(),
         {:ok, collection, attempt, _payment_intent} <-
           terminal_payment_application_identity(canonical_input),
         :ok <- ensure_collection_dispatch_reached(collection),
         true <-
           collection.financial_outcome in [
             :unresolved,
             :requires_action,
             :verified_terminal_financial_non_success
           ],
         {:ok, result} <- release_collection_generation_if_present(collection, attempt) do
      {:ok, result}
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "terminal collection settlement identity or outcome conflicts"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def release_terminal_collection_reservation_for_payment_application(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection settlement identity is required")}
  end

  @spec release_withdrawn_collection_reservation_for_cancellation(
          CancellationReservationInput.t()
        ) :: {:ok, map()} | {:error, Error.t() | term()}
  def release_withdrawn_collection_reservation_for_cancellation(
        %CancellationReservationInput{} = input
      ) do
    with {:ok, canonical_input} <- CancellationReservationInput.new(Map.from_struct(input)),
         :ok <- ensure_caller_transaction(),
         {:ok, attempt} <- fetch_renewal_attempt(canonical_input.renewal_attempt_id),
         true <- attempt.failure_code == @renewal_authority_withdrawn_code,
         {:ok, collections} <- fetch_collections(attempt.id),
         {:ok, collection} <- active_collection_for_reservation_release(collections),
         {:ok, result} <- release_collection_generation_if_present(collection, attempt) do
      {:ok, result}
    else
      false ->
        {:error, Error.new("RENEWAL_AUTHORITY_WITHDRAWN", "renewal authority is not withdrawn")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def release_withdrawn_collection_reservation_for_cancellation(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed cancellation reservation input is required")}
  end

  @spec assign_reservation_generation_for_system(ReservationGenerationInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def assign_reservation_generation_for_system(%ReservationGenerationInput{} = input) do
    with {:ok, canonical_input} <- ReservationGenerationInput.new(Map.from_struct(input)) do
      run_collection_transition(
        canonical_input.collection_attempt_id,
        :assign_renewal_collection_generation,
        fn collection, attempt, subscription ->
          assign_locked_generation(collection, attempt, subscription, canonical_input)
        end
      )
    end
  end

  def assign_reservation_generation_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed reservation generation input is required")}
  end

  @spec fence_before_submission_for_system(FenceInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def fence_before_submission_for_system(%FenceInput{} = input) do
    with {:ok, canonical_input} <- FenceInput.new(Map.from_struct(input)) do
      run_collection_transition(
        canonical_input.collection_attempt_id,
        :fence_renewal_collection_before_submission,
        fn collection, attempt, _subscription ->
          fence_locked_collection(collection, attempt, canonical_input)
        end
      )
    end
  end

  def fence_before_submission_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection fence input is required")}
  end

  @spec resume_after_fence_for_system(ResumeInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def resume_after_fence_for_system(%ResumeInput{} = input) do
    with {:ok, canonical_input} <- ResumeInput.new(Map.from_struct(input)) do
      run_collection_transition(
        canonical_input.collection_attempt_id,
        :resume_renewal_collection_after_fence,
        fn collection, attempt, subscription ->
          resume_locked_collection(collection, attempt, subscription, canonical_input)
        end
      )
    end
  end

  def resume_after_fence_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection resume input is required")}
  end

  defp ensure_caller_transaction do
    if Repo.in_transaction?() do
      :ok
    else
      {:error,
       Error.new(
         "INVALID_STATE_TRANSITION",
         "collection inventory settlement requires the payment application transaction"
       )}
    end
  end

  defp payment_application_settlement_identity(input) do
    query =
      from collection in RenewalCollectionAttempt,
        join: attempt in RenewalAttempt,
        on: attempt.id == collection.renewal_attempt_id,
        join: order in Order,
        on: order.id == attempt.order_id,
        join: payment_intent in PaymentIntent,
        on: payment_intent.id == collection.payment_intent_id,
        where: collection.id == ^input.collection_attempt_id,
        where: collection.renewal_attempt_id == ^input.renewal_attempt_id,
        where: collection.payment_intent_id == ^input.payment_intent_id,
        where: collection.dispatch_state == :may_have_been_reached,
        where: attempt.id == ^input.renewal_attempt_id,
        where: attempt.order_id == ^input.order_id,
        where: payment_intent.order_id == order.id,
        where: payment_intent.state == :succeeded,
        select: {collection, attempt}

    case Repo.one(query) do
      {%RenewalCollectionAttempt{} = collection, %RenewalAttempt{} = attempt} ->
        {:ok, collection, attempt}

      nil ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "collection settlement identity conflicts")}
    end
  end

  defp terminal_payment_application_identity(input) do
    query =
      from collection in RenewalCollectionAttempt,
        join: attempt in RenewalAttempt,
        on: attempt.id == collection.renewal_attempt_id,
        join: order in Order,
        on: order.id == attempt.order_id,
        join: payment_intent in PaymentIntent,
        on: payment_intent.id == collection.payment_intent_id,
        where:
          collection.id == ^input.collection_attempt_id and
            collection.renewal_attempt_id == ^input.renewal_attempt_id and
            collection.payment_intent_id == ^input.payment_intent_id and
            attempt.id == ^input.renewal_attempt_id and attempt.order_id == ^input.order_id and
            payment_intent.order_id == order.id and payment_intent.state == :failed,
        select: {collection, attempt, payment_intent}

    case Repo.one(query) do
      {%RenewalCollectionAttempt{} = collection, %RenewalAttempt{} = attempt,
       %PaymentIntent{} = payment_intent} ->
        {:ok, collection, attempt, payment_intent}

      nil ->
        {:error,
         Error.new("PAYMENT_EVENT_UNVERIFIED", "terminal collection identity is not exact")}
    end
  end

  defp active_collection_for_reservation_release(collections) do
    case Enum.filter(collections, &active_collection?/1) do
      [] ->
        {:ok, nil}

      [%RenewalCollectionAttempt{} = collection] ->
        {:ok, collection}

      _ ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal attempt has multiple active collection identities"
         )}
    end
  end

  defp release_collection_generation_if_present(nil, _attempt),
    do: {:ok, %{reservation: nil, changed?: false, inventory_variant_ids_to_invalidate: []}}

  defp release_collection_generation_if_present(
         %RenewalCollectionAttempt{reservation_generation_id: nil},
         _attempt
       ),
       do: {:ok, %{reservation: nil, changed?: false, inventory_variant_ids_to_invalidate: []}}

  defp release_collection_generation_if_present(
         %RenewalCollectionAttempt{} = collection,
         %RenewalAttempt{} = attempt
       ) do
    with {:ok, true} <- physical_renewal?(attempt.variant_id),
         {:ok, result} <- settle_collection_reservation(collection, attempt, true, :release) do
      {:ok, result}
    else
      {:ok, false} ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "nonphysical renewal collection cannot own an inventory generation"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_collection_dispatch_reached(%RenewalCollectionAttempt{
         dispatch_state: :may_have_been_reached
       }),
       do: :ok

  defp ensure_collection_dispatch_reached(_collection) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "successful renewal payment has no reached collection dispatch"
     )}
  end

  defp settle_collection_reservation(collection, _attempt, false, _action) do
    if is_nil(collection.reservation_generation_id) do
      {:ok, %{reservation: nil, changed?: false, inventory_variant_ids_to_invalidate: []}}
    else
      {:error,
       Error.new(
         "RESERVATION_CONFLICT",
         "nonphysical renewal collection cannot settle an inventory generation"
       )}
    end
  end

  defp settle_collection_reservation(
         %RenewalCollectionAttempt{reservation_generation_id: generation_id} = collection,
         attempt,
         true,
         action
       )
       when is_binary(generation_id) and action in [:consume, :release] do
    with {:ok, reservation_key} <- reservation_key_for_collection(collection, attempt),
         {:ok, %{reservation: %InventoryReservation{} = reservation, changed?: changed?}} <-
           Store.Orders.settle_exact_generation_in_caller_transaction(
             attempt.order_id,
             attempt.variant_id,
             reservation_key,
             action,
             now: DateTime.utc_now() |> DateTime.truncate(:microsecond)
           ),
         :ok <-
           ensure_settled_generation_identity(
             reservation,
             collection,
             attempt,
             reservation_key,
             action
           ) do
      {:ok,
       %{
         reservation: reservation,
         changed?: changed?,
         inventory_variant_ids_to_invalidate: if(changed?, do: [attempt.variant_id], else: [])
       }}
    end
  end

  defp settle_collection_reservation(
         %RenewalCollectionAttempt{reservation_generation_id: nil},
         _attempt,
         true,
         _action
       ) do
    {:error,
     Error.new(
       "RESERVATION_CONFLICT",
       "physical renewal collection has no assigned inventory generation"
     )}
  end

  defp ensure_settled_generation_identity(
         %InventoryReservation{} = reservation,
         collection,
         attempt,
         reservation_key,
         :consume
       ) do
    if reservation.id == collection.reservation_generation_id and
         reservation.order_id == attempt.order_id and
         reservation.variant_id == attempt.variant_id and
         reservation.reservation_key == reservation_key and
         reservation.quantity == attempt.quantity and reservation.state == :consumed do
      :ok
    else
      {:error,
       Error.new("RESERVATION_CONFLICT", "consumed inventory generation identity conflicts")}
    end
  end

  defp ensure_settled_generation_identity(
         %InventoryReservation{} = reservation,
         collection,
         attempt,
         reservation_key,
         :release
       ) do
    if reservation.id == collection.reservation_generation_id and
         reservation.order_id == attempt.order_id and
         reservation.variant_id == attempt.variant_id and
         reservation.reservation_key == reservation_key and
         reservation.quantity == attempt.quantity and
         reservation.state in [:cancelled, :expired] do
      :ok
    else
      {:error,
       Error.new("RESERVATION_CONFLICT", "released inventory generation identity conflicts")}
    end
  end

  defp run_collection_transition(collection_attempt_id, flow, transition) do
    run_collection_transition(collection_attempt_id, flow, transition, false)
  end

  defp run_collection_transition_with_result(collection_attempt_id, flow, transition) do
    run_collection_transition(collection_attempt_id, flow, transition, true)
  end

  defp run_collection_transition(collection_attempt_id, flow, transition, return_result?) do
    with {:ok, identity} <- fetch_collection_transition_identity(collection_attempt_id) do
      run_collection_transition_with_identity(
        collection_attempt_id,
        identity,
        flow,
        transition,
        return_result?
      )
    end
  end

  defp run_collection_transition_with_expected_identity(
         collection_attempt_id,
         identity,
         flow,
         transition
       ) do
    run_collection_transition_with_identity(
      collection_attempt_id,
      identity,
      flow,
      transition,
      true
    )
  end

  defp run_collection_transition_with_identity(
         collection_attempt_id,
         identity,
         flow,
         transition,
         return_result?
       ) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, subscription} <- fetch_subscription(identity.subscription_id),
             {:ok, attempt} <- fetch_renewal_attempt(identity.renewal_attempt_id, true),
             :ok <-
               ensure_transition_attempt_subscription(
                 attempt,
                 identity.subscription_id
               ),
             {:ok, collection} <- fetch_collection(collection_attempt_id),
             :ok <- ensure_transition_collection_attempt(collection, attempt) do
          apply_collection_transition(collection, attempt, subscription, transition)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transition_notifications()

    case transaction_result do
      {:ok,
       %{
         collection: %RenewalCollectionAttempt{} = collection,
         result: result
       }, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{flow: flow, collection_attempt_id: collection_attempt_id}
          )

        if return_result? do
          {:ok, collection, result}
        else
          {:ok, collection}
        end

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp apply_collection_transition(collection, attempt, subscription, transition) do
    case transition.(collection, attempt, subscription) do
      {:ok, %RenewalCollectionAttempt{} = updated, notifications, result} ->
        %{collection: updated, notifications: notifications, result: result}

      {:ok, %RenewalCollectionAttempt{} = updated, notifications} ->
        %{collection: updated, notifications: notifications, result: nil}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp assign_locked_generation(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached} = collection,
         attempt,
         _subscription,
         _input
       ) do
    with :ok <- SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt) do
      {:ok, collection, []}
    end
  end

  defp assign_locked_generation(collection, attempt, subscription, input) do
    with :ok <-
           SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_collection_dispatch_authority(subscription, attempt, input.now),
         {:ok, physical?} <- physical_renewal?(attempt.variant_id) do
      case {collection.dispatch_state, physical?, collection.reservation_generation_id} do
        {state, false, nil} when state in [:not_started, :may_have_been_reached] ->
          {:ok, collection, []}

        {state, false, _generation_id} when state in [:not_started, :may_have_been_reached] ->
          {:error,
           Error.new(
             "RESERVATION_CONFLICT",
             "nonphysical renewal collection cannot own an inventory generation"
           )}

        {:not_started, true, nil} ->
          assign_new_generation(collection, attempt, input.now)

        {state, true, generation_id}
        when state in [:not_started, :may_have_been_reached] and is_binary(generation_id) ->
          ensure_existing_generation(collection, attempt, generation_id)

        _ ->
          {:error,
           Error.new(
             "INVALID_STATE_TRANSITION",
             "collection cannot acquire an inventory generation in its current state"
           )}
      end
    end
  end

  defp assign_new_generation(collection, attempt, now) do
    with :ok <- ensure_bound_order(attempt),
         {:ok, reservation} <- reserve_new_generation(collection, attempt, now),
         :ok <-
           guard_collection_generation(
             collection,
             attempt,
             reservation.reservation_key,
             reservation.id
           ) do
      update_collection(collection, :assign_reservation_generation, %{
        reservation_generation_id: reservation.id
      })
    end
  end

  defp ensure_existing_generation(collection, attempt, generation_id) do
    with :ok <- ensure_bound_order(attempt),
         {:ok, reservation_key} <- reservation_key_for_collection(collection, attempt),
         :ok <- guard_collection_generation(collection, attempt, reservation_key, generation_id) do
      {:ok, collection, []}
    end
  end

  defp attach_payment_intent_locked(collection, attempt, subscription, input) do
    with :ok <- SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_collection_can_bind_payment_intent(collection, input.payment_intent_id),
         :ok <- ensure_bound_order(attempt),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(input.payment_intent_id),
         :ok <- ensure_bound_order_matches_attempt(order, attempt),
         :ok <-
           ensure_payment_intent_matches_collection(
             payment_intent,
             collection,
             order,
             attempt,
             subscription
           ),
         {:ok, updated, notifications} <-
           update_collection(collection, :attach_payment_intent, %{
             payment_intent_id: payment_intent.id
           }) do
      {:ok, updated, notifications,
       %{renewal_attempt: attempt, order: order, payment_intent: payment_intent}}
    end
  end

  defp claim_dispatch_locked(collection, attempt, subscription, input) do
    with :ok <- ensure_exact_dispatch_epoch(collection, input.expected_epoch),
         :ok <- SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_bound_order(attempt),
         :ok <- ensure_collection_has_exact_payment_intent(collection),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(collection.payment_intent_id),
         :ok <- ensure_bound_order_matches_attempt(order, attempt),
         :ok <-
           ensure_payment_intent_matches_collection(
             payment_intent,
             collection,
             order,
             attempt,
             subscription
           ),
         :ok <- ensure_collection_has_exact_inventory_generation(collection, attempt),
         {:ok, payment_intent, provider_payment_method, method_notifications} <-
           prepare_dispatch_provider_method(
             collection,
             payment_intent,
             subscription,
             attempt,
             input.now
           ),
         {:ok, updated, notifications} <-
           claim_collection_dispatch(collection, input.expected_epoch) do
      {:ok, updated, method_notifications ++ notifications,
       %{
         subscription: subscription,
         renewal_attempt: attempt,
         order: order,
         payment_intent: payment_intent,
         provider_payment_method: provider_payment_method
       }}
    end
  end

  defp replay_dispatch_locked(collection, attempt, subscription, input) do
    with :ok <- ensure_exact_replay_dispatch_epoch(collection, input.expected_epoch),
         :ok <- SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_bound_order(attempt),
         :ok <- ensure_collection_has_exact_payment_intent(collection),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(collection.payment_intent_id),
         :ok <- ensure_bound_order_matches_attempt(order, attempt),
         :ok <-
           ensure_payment_intent_matches_collection(
             payment_intent,
             collection,
             order,
             attempt,
             subscription
           ),
         :ok <- Providers.ensure_enabled_provider(subscription.provider),
         {:ok, provider_payment_method} <- provider_method_from_payment_intent(payment_intent) do
      {:ok, collection, [],
       %{
         subscription: subscription,
         renewal_attempt: attempt,
         order: order,
         payment_intent: payment_intent,
         provider_payment_method: provider_payment_method
       }}
    end
  end

  defp prepare_dispatch_provider_method(
         %RenewalCollectionAttempt{dispatch_state: :not_started},
         %PaymentIntent{} = payment_intent,
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         now
       ) do
    with :ok <- ensure_collection_dispatch_authority(subscription, attempt, now),
         :ok <- Providers.ensure_enabled_provider(subscription.provider),
         {:ok, provider_payment_method} <- lock_active_stored_payment_method(subscription),
         {:ok, updated_payment_intent, notifications} <-
           bind_dispatch_provider_method(payment_intent, provider_payment_method) do
      {:ok, updated_payment_intent, provider_payment_method, notifications}
    end
  end

  defp prepare_dispatch_provider_method(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached},
         %PaymentIntent{} = payment_intent,
         %Subscription{} = subscription,
         _attempt,
         _now
       ) do
    with :ok <- Providers.ensure_enabled_provider(subscription.provider),
         {:ok, provider_payment_method} <- provider_method_from_payment_intent(payment_intent) do
      {:ok, payment_intent, provider_payment_method, []}
    end
  end

  defp prepare_dispatch_provider_method(
         _collection,
         _payment_intent,
         _subscription,
         _attempt,
         _now
       ) do
    {:error, Error.new("STALE_RECORD", "collection is not at a dispatchable state")}
  end

  defp bind_dispatch_provider_method(
         %PaymentIntent{} = payment_intent,
         %{provider_customer_ref: customer_ref, provider_payment_method_ref: method_ref}
       )
       when is_binary(customer_ref) and customer_ref != "" and is_binary(method_ref) and
              method_ref != "" do
    case {payment_intent.provider_customer_ref, payment_intent.provider_payment_method_ref} do
      {nil, nil} ->
        update_payment_intent_provider_method(payment_intent, customer_ref, method_ref)

      {^customer_ref, ^method_ref} ->
        if payment_intent.state == :created do
          prepare_payment_intent_for_dispatch(payment_intent, customer_ref, method_ref)
        else
          {:ok, payment_intent, []}
        end

      _conflicting_reference ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "PaymentIntent already has a conflicting provider method identity"
         )}
    end
  end

  defp bind_dispatch_provider_method(_payment_intent, _provider_payment_method) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "provider payment method identity is incomplete"
     )}
  end

  defp update_payment_intent_provider_method(
         %PaymentIntent{state: :created} = payment_intent,
         customer_ref,
         method_ref
       ),
       do: prepare_payment_intent_for_dispatch(payment_intent, customer_ref, method_ref)

  defp update_payment_intent_provider_method(payment_intent, customer_ref, method_ref) do
    payment_intent
    |> Ash.Changeset.for_update(
      :set_provider_reference,
      %{
        provider_customer_ref: customer_ref,
        provider_payment_method_ref: method_ref
      },
      context: %{system?: true}
    )
    |> update_payment_intent_with_notifications()
  end

  defp prepare_payment_intent_for_dispatch(payment_intent, customer_ref, method_ref) do
    payment_intent
    |> Ash.Changeset.for_update(
      :prepare_renewal_dispatch,
      %{
        provider_customer_ref: customer_ref,
        provider_payment_method_ref: method_ref
      },
      context: %{system?: true}
    )
    |> update_payment_intent_with_notifications()
  end

  defp update_payment_intent_with_notifications(changeset) do
    case Ash.update(changeset,
           domain: Store.Payments,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %PaymentIntent{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %PaymentIntent{} = updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp provider_method_from_payment_intent(%PaymentIntent{
         provider_customer_ref: customer_ref,
         provider_payment_method_ref: method_ref
       })
       when is_binary(customer_ref) and customer_ref != "" and is_binary(method_ref) and
              method_ref != "" do
    {:ok,
     %{
       provider_customer_ref: customer_ref,
       provider_payment_method_ref: method_ref
     }}
  end

  defp provider_method_from_payment_intent(_payment_intent) do
    {:error,
     Error.new(
       "PAYMENT_OUTCOME_UNRESOLVED",
       "reached renewal dispatch has no persisted provider method identity",
       %{existing_collection_replay?: true}
     )}
  end

  defp ensure_generation_before_dispatch_or_replay(
         %RenewalCollectionAttempt{dispatch_state: :not_started} = collection,
         attempt
       ),
       do: ensure_collection_has_exact_inventory_generation(collection, attempt)

  defp ensure_generation_before_dispatch_or_replay(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached},
         _attempt
       ),
       do: :ok

  defp ensure_generation_before_dispatch_or_replay(_collection, _attempt) do
    {:error, Error.new("STALE_RECORD", "collection is not at a dispatchable epoch")}
  end

  defp record_financial_outcome_locked(collection, input) do
    with :ok <- ensure_collection_payment_identity(collection, input.payment_intent_id),
         {:ok, payment_intent} <- fetch_payment_intent(input.payment_intent_id),
         :ok <- ensure_payment_outcome_matches_intent(payment_intent, input.financial_outcome),
         :ok <- ensure_financial_outcome_transition(collection, input.financial_outcome) do
      update_collection(collection, :record_financial_outcome, %{
        financial_outcome: input.financial_outcome
      })
    end
  end

  defp ensure_collection_payment_identity(
         %RenewalCollectionAttempt{payment_intent_id: payment_intent_id},
         payment_intent_id
       )
       when is_binary(payment_intent_id),
       do: :ok

  defp ensure_collection_payment_identity(_collection, _payment_intent_id) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "financial outcome does not match the exact collection"
     )}
  end

  defp ensure_payment_outcome_matches_intent(
         %PaymentIntent{state: :requires_action},
         :requires_action
       ),
       do: :ok

  defp ensure_payment_outcome_matches_intent(
         %PaymentIntent{state: :succeeded},
         :verified_success
       ),
       do: :ok

  defp ensure_payment_outcome_matches_intent(
         %PaymentIntent{state: state},
         :verified_terminal_financial_non_success
       )
       when state in [:failed, :cancelled],
       do: :ok

  defp ensure_payment_outcome_matches_intent(_payment_intent, _outcome) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "Payments finality result does not match the exact PaymentIntent state"
     )}
  end

  defp ensure_financial_outcome_transition(
         %RenewalCollectionAttempt{financial_outcome: current},
         target
       )
       when current == target and
              target in [
                :requires_action,
                :verified_success,
                :verified_terminal_financial_non_success
              ],
       do: :ok

  defp ensure_financial_outcome_transition(
         %RenewalCollectionAttempt{financial_outcome: current},
         target
       )
       when current in [:unresolved, :requires_action] and
              target in [
                :requires_action,
                :verified_success,
                :verified_terminal_financial_non_success
              ],
       do: :ok

  defp ensure_financial_outcome_transition(_collection, _target) do
    {:error,
     Error.new(
       "INVALID_STATE_TRANSITION",
       "terminal collection financial outcome cannot regress"
     )}
  end

  defp lock_active_stored_payment_method(%Subscription{
         stored_payment_method_id: payment_method_id,
         user_id: user_id,
         provider: provider
       })
       when is_binary(payment_method_id) and is_binary(user_id) do
    query = """
    SELECT id::text, user_id::text, provider::text, status::text,
           provider_customer_ref, provider_payment_method_ref
    FROM stored_payment_methods
    WHERE id = $1::text::uuid AND user_id = $2::text::uuid
    FOR UPDATE
    """

    case Repo.query(query, [payment_method_id, user_id]) do
      {:ok, result} ->
        stored_payment_method_from_result(result, payment_method_id, user_id, provider)

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp lock_active_stored_payment_method(_subscription) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription has no current active provider payment method"
     )}
  end

  defp stored_payment_method_from_result(
         %{
           rows: [[payment_method_id, user_id, stored_provider, status, customer_ref, method_ref]]
         },
         payment_method_id,
         user_id,
         provider
       ) do
    if valid_stored_payment_method?(stored_provider, status, customer_ref, method_ref, provider) do
      {:ok,
       %{
         provider_customer_ref: customer_ref,
         provider_payment_method_ref: method_ref
       }}
    else
      {:error,
       Error.new(
         "PAYMENT_METHOD_REQUIRED",
         "current provider payment method is inactive or does not match the subscription"
       )}
    end
  end

  defp stored_payment_method_from_result(%{rows: []}, _payment_method_id, _user_id, _provider) do
    {:error,
     Error.new(
       "PAYMENT_METHOD_REQUIRED",
       "subscription has no current active provider payment method"
     )}
  end

  defp stored_payment_method_from_result(_result, _payment_method_id, _user_id, _provider) do
    {:error, Error.new("PAYMENT_METHOD_REQUIRED", "current provider payment method is invalid")}
  end

  defp valid_stored_payment_method?(stored_provider, status, customer_ref, method_ref, provider) do
    stored_provider == Atom.to_string(provider) and status == "active" and
      present_binary?(customer_ref) and present_binary?(method_ref)
  end

  defp present_binary?(value), do: is_binary(value) and value != ""

  defp ensure_exact_dispatch_epoch(
         %RenewalCollectionAttempt{
           dispatch_state: :not_started,
           financial_outcome: :unresolved,
           dispatch_epoch: epoch,
           fenced_through_epoch: fenced_through_epoch
         },
         epoch
       )
       when fenced_through_epoch == epoch - 1,
       do: :ok

  defp ensure_exact_dispatch_epoch(_collection, _expected_epoch) do
    {:error, Error.new("STALE_RECORD", "collection is not at the exact dispatch epoch to claim")}
  end

  defp ensure_exact_replay_dispatch_epoch(
         %RenewalCollectionAttempt{
           dispatch_state: :may_have_been_reached,
           financial_outcome: financial_outcome,
           dispatch_epoch: epoch
         },
         epoch
       )
       when financial_outcome in [:unresolved, :requires_action],
       do: :ok

  defp ensure_exact_replay_dispatch_epoch(_collection, _expected_epoch) do
    {:error,
     Error.new(
       "STALE_RECORD",
       "collection is not at the exact unresolved dispatch epoch to replay"
     )}
  end

  defp ensure_collection_has_exact_payment_intent(%RenewalCollectionAttempt{
         payment_intent_id: payment_intent_id
       })
       when is_binary(payment_intent_id),
       do: :ok

  defp ensure_collection_has_exact_payment_intent(_collection) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "collection has no exact bound PaymentIntent")}
  end

  defp ensure_collection_has_exact_inventory_generation(collection, attempt) do
    with {:ok, physical?} <- physical_renewal?(attempt.variant_id) do
      case {physical?, collection.reservation_generation_id} do
        {false, nil} ->
          :ok

        {false, _generation_id} ->
          {:error,
           Error.new(
             "RESERVATION_CONFLICT",
             "nonphysical renewal collection cannot own an inventory generation"
           )}

        {true, nil} ->
          {:error,
           Error.new(
             "RESERVATION_CONFLICT",
             "physical renewal collection has no exact inventory generation"
           )}

        {true, generation_id} ->
          guard_existing_collection_generation(collection, attempt, generation_id)
      end
    end
  end

  defp guard_existing_collection_generation(collection, attempt, generation_id) do
    with {:ok, reservation_key} <- reservation_key_for_collection(collection, attempt) do
      guard_collection_generation(collection, attempt, reservation_key, generation_id)
    end
  end

  defp claim_collection_dispatch(collection, expected_epoch) do
    changeset =
      collection
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:expected_epoch, expected_epoch)
      |> Ash.Changeset.for_update(
        :claim_dispatch,
        %{},
        context: %{system?: true}
      )

    case Ash.update(changeset,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %RenewalCollectionAttempt{} = updated, notifications} ->
        {:ok, updated, notifications}

      {:ok, %RenewalCollectionAttempt{} = updated} ->
        {:ok, updated, []}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_collection_can_bind_payment_intent(
         %RenewalCollectionAttempt{payment_intent_id: payment_intent_id},
         payment_intent_id
       )
       when is_binary(payment_intent_id),
       do: :ok

  defp ensure_collection_can_bind_payment_intent(
         %RenewalCollectionAttempt{
           payment_intent_id: nil,
           dispatch_state: :not_started,
           financial_outcome: :unresolved
         },
         _payment_intent_id
       ),
       do: :ok

  defp ensure_collection_can_bind_payment_intent(_collection, _payment_intent_id) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "collection cannot bind a different or late PaymentIntent"
     )}
  end

  defp ensure_bound_order_matches_attempt(
         %Order{} = order,
         %RenewalAttempt{} = attempt
       ) do
    expected_subtotal = attempt.amount_minor * attempt.quantity

    with true <- order.id == attempt.order_id,
         true <- not is_nil(order.totals_finalized_at),
         true <- String.upcase(order.currency_code || "") == attempt.currency,
         true <- order.items_subtotal_minor == expected_subtotal,
         {:ok, line_items} <- fetch_order_line_items(order.id),
         true <- exact_bound_order_line?(line_items, attempt) do
      :ok
    else
      false ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "renewal Order conflicts with the immutable bound contract"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_bound_order_line?([line_item], attempt) do
    line_item.variant_id_snapshot == attempt.variant_id and
      line_item.quantity == attempt.quantity and
      line_item.unit_price_minor == attempt.amount_minor and
      line_item.line_total_minor == attempt.amount_minor * attempt.quantity and
      String.upcase(line_item.currency || "") == attempt.currency
  end

  defp exact_bound_order_line?(_line_items, _attempt), do: false

  defp ensure_payment_intent_matches_collection(
         %PaymentIntent{} = payment_intent,
         %RenewalCollectionAttempt{} = collection,
         %Order{} = order,
         %RenewalAttempt{} = attempt,
         %Subscription{} = subscription
       ) do
    expected_key = payment_intent_key(collection.id)

    if payment_intent.order_id == order.id and
         payment_intent.payment_intent_key == expected_key and
         payment_intent.amount_received_minor == order.grand_total_minor and
         String.upcase(payment_intent.currency || "") == attempt.currency and
         payment_intent.provider == subscription.provider and
         is_binary(payment_intent.provider_request_reference) and
         payment_intent.provider_request_reference != "" do
      :ok
    else
      {:error,
       Error.new(
         "PAYMENT_EVENT_UNVERIFIED",
         "PaymentIntent conflicts with the exact collection Order or bound contract"
       )}
    end
  end

  defp fetch_order(order_id) when is_binary(order_id) do
    query = Order |> Ash.Query.filter(expr(id == ^order_id))

    case Ash.read_one(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, %Order{} = order} -> {:ok, order}
      {:ok, nil} -> {:error, Error.new("ORDER_NOT_FOUND", "renewal Order was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_order(_order_id) do
    {:error, Error.new("ORDER_NOT_FOUND", "renewal attempt has no bound Order")}
  end

  defp fetch_order_line_items(order_id) do
    query =
      OrderLineItem
      |> Ash.Query.filter(expr(order_id == ^order_id))
      |> Ash.Query.sort(line_no: :asc)

    case Ash.read(query, domain: Store.Orders, authorize?: false, context: %{system?: true}) do
      {:ok, line_items} -> {:ok, line_items}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_payment_intent(payment_intent_id) when is_binary(payment_intent_id) do
    query = PaymentIntent |> Ash.Query.filter(expr(id == ^payment_intent_id))

    case Ash.read_one(query,
           domain: Store.Payments,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %PaymentIntent{} = payment_intent} -> {:ok, payment_intent}
      {:ok, nil} -> {:error, Error.new("PAYMENT_INTENT_NOT_FOUND", "PaymentIntent was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fence_locked_collection(collection, attempt, input) do
    # Fencing before inventory assignment is valid: there is no generation to release,
    # and a later physical dispatch must acquire and guard one during resume.
    with :ok <- ensure_exact_fence_epoch(collection, input.expected_epoch),
         :ok <-
           release_collection_generation_before_fence(
             collection,
             attempt,
             input.now
           ) do
      update_collection(collection, :fence_before_submission, %{
        dispatch_state: :not_submitted,
        fenced_through_epoch: input.expected_epoch,
        last_fence_event_id: UUIDv7.generate(),
        last_fenced_at: input.now
      })
    end
  end

  defp resume_locked_collection(collection, attempt, subscription, input) do
    with :ok <- ensure_exact_resume_epoch(collection, input.expected_epoch),
         :ok <-
           SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_collection_dispatch_authority(subscription, attempt, input.now),
         {:ok, physical?} <- physical_renewal?(attempt.variant_id),
         {:ok, generation_id, reservation} <-
           resume_generation(collection, attempt, physical?, input.now),
         :ok <- maybe_guard_resume_generation(collection, attempt, physical?, reservation) do
      update_collection(collection, :resume_after_fence, %{
        dispatch_state: :not_started,
        dispatch_epoch: input.expected_epoch + 1,
        reservation_generation_id: generation_id
      })
    end
  end

  defp resume_generation(collection, attempt, true, now) do
    with :ok <- ensure_bound_order(attempt),
         {:ok, reservation} <- reserve_new_generation(collection, attempt, now) do
      {:ok, reservation.id, reservation}
    end
  end

  defp resume_generation(
         %RenewalCollectionAttempt{reservation_generation_id: nil},
         _attempt,
         false,
         _now
       ),
       do: {:ok, nil, nil}

  defp resume_generation(_collection, _attempt, false, _now) do
    {:error,
     Error.new(
       "RESERVATION_CONFLICT",
       "nonphysical renewal collection cannot own an inventory generation"
     )}
  end

  defp maybe_guard_resume_generation(_collection, _attempt, false, nil), do: :ok

  defp maybe_guard_resume_generation(collection, attempt, true, reservation) do
    guard_collection_generation(
      collection,
      attempt,
      reservation.reservation_key,
      reservation.id
    )
  end

  defp reserve_new_generation(collection, attempt, now) do
    with :ok <- ensure_bound_order(attempt),
         {:ok, request} <-
           Request.new_renewal_generation(
             attempt.order_id,
             attempt.variant_id,
             collection.id,
             UUIDv7.generate(),
             attempt.quantity
           ) do
      case Store.Orders.reserve_exact_generation(
             attempt.order_id,
             attempt.variant_id,
             request.reservation_key,
             attempt.quantity,
             now: now
           ) do
        {:ok, %{reservation: %InventoryReservation{} = reservation}} ->
          {:ok, reservation}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    end
  end

  defp guard_collection_generation(collection, attempt, reservation_key, expected_id) do
    with :ok <-
           validate_collection_generation_key(
             reservation_key,
             collection.id,
             attempt
           ),
         {:ok, facts} <-
           Store.Orders.guard_exact_generation(
             attempt.order_id,
             attempt.variant_id,
             reservation_key,
             attempt.quantity
           ),
         true <- facts.id == expected_id and facts.state == :active do
      :ok
    else
      {:error, reason} ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "exact renewal inventory generation is not active or does not match the collection",
           %{reason: inspect(reason)}
         )}

      false ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "exact renewal inventory generation does not match the assigned row"
         )}
    end
  end

  defp release_collection_generation_before_fence(
         %RenewalCollectionAttempt{reservation_generation_id: nil},
         _attempt,
         _now
       ),
       do: :ok

  defp release_collection_generation_before_fence(collection, attempt, now) do
    with :ok <- ensure_bound_order(attempt),
         {:ok, reservation_key} <- reservation_key_for_collection(collection, attempt),
         {:ok, %{reservation: %InventoryReservation{} = reservation}} <-
           Store.Orders.release_exact_generation(
             attempt.order_id,
             attempt.variant_id,
             reservation_key,
             now: now
           ),
         true <- reservation.id == collection.reservation_generation_id,
         true <- reservation.state in [:cancelled, :expired] do
      :ok
    else
      {:error, reason} ->
        {:error, Normalize.normalize(reason)}

      _ ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "pre-submission fence could not release its exact active generation"
         )}
    end
  end

  defp reservation_key_for_collection(collection, attempt) do
    case Repo.get(InventoryReservation, collection.reservation_generation_id) do
      %InventoryReservation{reservation_key: key} when is_binary(key) ->
        case validate_collection_generation_key(key, collection.id, attempt) do
          :ok -> {:ok, key}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "assigned renewal reservation generation is missing"
         )}
    end
  end

  defp validate_collection_generation_key(reservation_key, collection_attempt_id, attempt) do
    case Request.classify_reservation_key(reservation_key) do
      {:ok,
       {:renewal_generation,
        %{
          order_id: order_id,
          variant_id: variant_id,
          collection_attempt_id: ^collection_attempt_id
        }}} ->
        if order_id == attempt.order_id and variant_id == attempt.variant_id do
          :ok
        else
          {:error, :contradictory_identity}
        end

      _ ->
        {:error, :invalid_reservation_key}
    end
  end

  defp ensure_bound_order(%RenewalAttempt{order_id: order_id}) when is_binary(order_id), do: :ok

  defp ensure_bound_order(_attempt) do
    {:error,
     Error.new("VALIDATION_ERROR", "renewal Order must be bound before inventory assignment")}
  end

  defp ensure_exact_fence_epoch(
         %RenewalCollectionAttempt{
           dispatch_state: :not_started,
           financial_outcome: :unresolved,
           dispatch_epoch: epoch,
           fenced_through_epoch: fenced_through_epoch
         },
         epoch
       )
       when fenced_through_epoch == epoch - 1,
       do: :ok

  defp ensure_exact_fence_epoch(_collection, _expected_epoch) do
    {:error,
     Error.new(
       "STALE_RECORD",
       "collection is not at the exact not-started dispatch epoch to fence"
     )}
  end

  defp ensure_exact_resume_epoch(
         %RenewalCollectionAttempt{
           dispatch_state: :not_submitted,
           financial_outcome: :unresolved,
           dispatch_epoch: epoch,
           fenced_through_epoch: epoch
         },
         epoch
       ),
       do: :ok

  defp ensure_exact_resume_epoch(_collection, _expected_epoch) do
    {:error,
     Error.new(
       "STALE_RECORD",
       "collection is not at the exact fenced dispatch epoch to resume"
     )}
  end

  defp ensure_collection_dispatch_authority(subscription, attempt, now) do
    with :ok <- ensure_collection_attempt_dispatchable(attempt),
         :ok <- ensure_renewal_authority(subscription, attempt),
         :ok <- ensure_bound_period_is_current(subscription, attempt),
         :ok <- ensure_due_for_collection(subscription, now) do
      ensure_collection_retry_authority(subscription, attempt)
    end
  end

  defp ensure_collection_attempt_dispatchable(%RenewalAttempt{status: :succeeded}) do
    {:error,
     Error.new(
       "INVALID_STATE_TRANSITION",
       "a succeeded renewal attempt cannot start or resume collection dispatch"
     )}
  end

  defp ensure_collection_attempt_dispatchable(%RenewalAttempt{}), do: :ok

  defp ensure_collection_retry_authority(%Subscription{status: :active}, _attempt), do: :ok

  defp ensure_collection_retry_authority(
         %Subscription{status: :past_due, dunning_attempt_count: count},
         %RenewalAttempt{charged_contract_snapshot: snapshot}
       ) do
    max_retry_attempts = Map.get(snapshot, "max_retry_attempts")

    if is_integer(count) and count > 0 and is_integer(max_retry_attempts) and
         count <= max_retry_attempts do
      :ok
    else
      {:error,
       Error.new(
         "INVALID_STATE_TRANSITION",
         "renewal retry policy does not permit provider dispatch"
       )}
    end
  end

  defp ensure_collection_retry_authority(_subscription, _attempt) do
    {:error, Error.new("RENEWAL_AUTHORITY_WITHDRAWN", "renewal authority is withdrawn")}
  end

  defp physical_renewal?(variant_id) do
    query = Variant |> Ash.Query.filter(expr(id == ^variant_id))

    case Ash.read_one(query,
           domain: Store.Catalog,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %Variant{weight_grams: weight_grams}} when is_integer(weight_grams) ->
        {:ok, weight_grams > 0}

      {:ok, %Variant{}} ->
        {:ok, false}

      {:ok, nil} ->
        {:error, Error.new("NOT_FOUND", "bound renewal variant was not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp update_collection(collection, action, attrs) do
    changeset =
      collection
      |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})

    case Ash.update(changeset,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %RenewalCollectionAttempt{} = updated, notifications} ->
        {:ok, updated, notifications}

      {:ok, %RenewalCollectionAttempt{} = updated} ->
        {:ok, updated, []}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp start_locked(%RenewalAttempt{} = attempt, input) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, subscription} <- fetch_subscription(attempt.subscription_id),
             {:ok, locked_attempt} <- fetch_renewal_attempt(attempt.id, true),
             :ok <-
               ensure_transition_attempt_subscription(
                 locked_attempt,
                 subscription.id
               ),
             {:ok, collections} <- fetch_collections(locked_attempt.id),
             {:ok, collection, notifications} <-
               start_or_replay(locked_attempt, subscription, collections, input) do
          %{collection: collection, notifications: notifications}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{collection: %RenewalCollectionAttempt{} = collection}, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{flow: :start_renewal_collection, renewal_attempt_id: attempt.id}
          )

        {:ok, collection}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp start_and_assign_locked(subscription_id, input) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, subscription} <- fetch_subscription(subscription_id),
             {:ok, locked_attempt} <- fetch_renewal_attempt(input.renewal_attempt_id, true),
             :ok <- ensure_transition_attempt_subscription(locked_attempt, subscription.id),
             {:ok, collections} <- fetch_collections(locked_attempt.id),
             {:ok, collection, start_notifications} <-
               start_or_replay(locked_attempt, subscription, collections, input),
             {:ok, resumed_collection, resume_notifications} <-
               resume_collection_if_fenced(collection, locked_attempt, subscription, input.now),
             {:ok, assigned_collection, assign_notifications} <-
               assign_locked_generation(
                 resumed_collection,
                 locked_attempt,
                 subscription,
                 %ReservationGenerationInput{
                   collection_attempt_id: resumed_collection.id,
                   now: input.now
                 }
               ) do
          %{
            collection: assigned_collection,
            notifications: start_notifications ++ resume_notifications ++ assign_notifications
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_notifications()

    case transaction_result do
      {:ok, %{collection: %RenewalCollectionAttempt{} = collection}, notifications} ->
        :ok =
          AshNotifications.notify_post_commit(notifications,
            context: %{
              flow: :start_and_assign_renewal_collection,
              renewal_attempt_id: input.renewal_attempt_id
            }
          )

        {:ok, collection}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp start_input_subscription_id(%StartInput{subscription_id: subscription_id})
       when is_binary(subscription_id),
       do: {:ok, subscription_id}

  defp start_input_subscription_id(%StartInput{renewal_attempt_id: renewal_attempt_id}) do
    with {:ok, attempt} <- fetch_renewal_attempt(renewal_attempt_id) do
      {:ok, attempt.subscription_id}
    end
  end

  defp resume_collection_if_fenced(
         %RenewalCollectionAttempt{dispatch_state: :not_submitted} = collection,
         attempt,
         subscription,
         now
       ) do
    resume_locked_collection(
      collection,
      attempt,
      subscription,
      %ResumeInput{
        collection_attempt_id: collection.id,
        expected_epoch: collection.dispatch_epoch,
        now: now
      }
    )
  end

  defp resume_collection_if_fenced(
         %RenewalCollectionAttempt{} = collection,
         _attempt,
         _subscription,
         _now
       ),
       do: {:ok, collection, []}

  defp attach_and_claim_dispatch_locked(collection, attempt, subscription, input) do
    with :ok <- SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_collection_can_bind_payment_intent(collection, input.payment_intent_id),
         :ok <- ensure_bound_order(attempt),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(input.payment_intent_id),
         :ok <- ensure_bound_order_matches_attempt(order, attempt),
         :ok <-
           ensure_payment_intent_matches_collection(
             payment_intent,
             collection,
             order,
             attempt,
             subscription
           ),
         {:ok, bound_collection, bind_notifications} <-
           bind_collection_payment_intent(collection, payment_intent.id),
         :ok <- ensure_collection_has_exact_dispatch_epoch(bound_collection, input),
         :ok <-
           ensure_generation_before_dispatch_or_replay(
             bound_collection,
             attempt
           ),
         {:ok, payment_intent, provider_payment_method, method_notifications} <-
           prepare_dispatch_provider_method(
             bound_collection,
             payment_intent,
             subscription,
             attempt,
             input.now
           ),
         {:ok, updated_attempt, attempt_notifications} <-
           maybe_mirror_collection_payment_intent(attempt, order, payment_intent),
         {:ok, updated_collection, dispatch_notifications} <-
           claim_or_replay_collection_dispatch(
             bound_collection,
             payment_intent.id,
             input.expected_epoch
           ) do
      {:ok, updated_collection,
       bind_notifications ++
         method_notifications ++
         attempt_notifications ++
         dispatch_notifications,
       %{
         renewal_attempt: updated_attempt,
         order: order,
         payment_intent: payment_intent,
         provider_payment_method: provider_payment_method
       }}
    end
  end

  defp maybe_mirror_collection_payment_intent(
         %RenewalAttempt{payment_intent_id: nil} = attempt,
         %Order{} = order,
         %PaymentIntent{} = payment_intent
       ) do
    attempt
    |> Ash.Changeset.for_update(
      :mark_processing,
      %{order_id: order.id, payment_intent_id: payment_intent.id},
      context: %{system?: true}
    )
    |> Ash.update(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %RenewalAttempt{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %RenewalAttempt{} = updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp maybe_mirror_collection_payment_intent(
         %RenewalAttempt{} = attempt,
         _order,
         _payment_intent
       ),
       do: {:ok, attempt, []}

  defp bind_collection_payment_intent(collection, payment_intent_id) do
    case collection.payment_intent_id do
      ^payment_intent_id ->
        {:ok, collection, []}

      nil when collection.dispatch_state == :not_started ->
        {:ok, collection, []}

      nil ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "reached collection has no exact bound PaymentIntent"
         )}

      _other_id ->
        {:error,
         Error.new(
           "PAYMENT_EVENT_UNVERIFIED",
           "collection cannot bind a different or late PaymentIntent"
         )}
    end
  end

  defp ensure_collection_has_exact_dispatch_epoch(
         %RenewalCollectionAttempt{dispatch_state: :not_started} = collection,
         %AttachAndClaimInput{expected_epoch: epoch}
       ),
       do: ensure_exact_dispatch_epoch(collection, epoch)

  defp ensure_collection_has_exact_dispatch_epoch(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached} = collection,
         %AttachAndClaimInput{expected_epoch: epoch}
       ),
       do: ensure_exact_replay_dispatch_epoch(collection, epoch)

  defp ensure_collection_has_exact_dispatch_epoch(_collection, _input) do
    {:error, Error.new("STALE_RECORD", "collection dispatch epoch is not replayable")}
  end

  defp claim_or_replay_collection_dispatch(
         %RenewalCollectionAttempt{dispatch_state: :not_started} = collection,
         payment_intent_id,
         expected_epoch
       ),
       do: attach_and_claim_collection_dispatch(collection, payment_intent_id, expected_epoch)

  defp claim_or_replay_collection_dispatch(
         %RenewalCollectionAttempt{dispatch_state: :may_have_been_reached} = collection,
         payment_intent_id,
         _expected_epoch
       ) do
    case collection.payment_intent_id do
      ^payment_intent_id ->
        {:ok, collection, []}

      _ ->
        {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "replay PaymentIntent identity changed")}
    end
  end

  defp attach_and_claim_collection_dispatch(collection, payment_intent_id, expected_epoch) do
    changeset =
      collection
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_argument(:payment_intent_id, payment_intent_id)
      |> Ash.Changeset.set_argument(:expected_epoch, expected_epoch)
      |> Ash.Changeset.for_update(:attach_and_claim_dispatch, %{}, context: %{system?: true})

    case Ash.update(changeset,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %RenewalCollectionAttempt{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %RenewalCollectionAttempt{} = updated} -> {:ok, updated, []}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp start_or_replay(attempt, subscription, collections, input) do
    case Enum.find(collections, &active_collection?/1) do
      %RenewalCollectionAttempt{} = active ->
        {:ok, active, []}

      nil ->
        with :ok <- ensure_legacy_attempt_is_unclaimed(attempt, collections),
             :ok <- ensure_contiguous_ordinals(collections),
             :ok <- ensure_no_success(collections),
             :ok <-
               SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
             :ok <- ensure_collection_start_authority(subscription, attempt, collections, input) do
          create_next_collection(attempt, collections)
        end
    end
  end

  defp ensure_legacy_attempt_is_unclaimed(_attempt, [_collection | _rest]), do: :ok

  defp ensure_legacy_attempt_is_unclaimed(
         %RenewalAttempt{status: :succeeded},
         []
       ) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "legacy succeeded renewal has no exact collection identity and requires reconciliation"
     )}
  end

  defp ensure_legacy_attempt_is_unclaimed(
         %RenewalAttempt{payment_intent_id: payment_intent_id},
         []
       )
       when is_binary(payment_intent_id) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "legacy renewal PaymentIntent must be reconciled before a collection can be started"
     )}
  end

  defp ensure_legacy_attempt_is_unclaimed(%RenewalAttempt{}, []), do: :ok

  defp create_next_collection(attempt, collections) do
    ordinal = length(collections) + 1

    changeset =
      RenewalCollectionAttempt
      |> Ash.Changeset.for_create(
        :create,
        %{renewal_attempt_id: attempt.id, collection_ordinal: ordinal},
        context: %{system?: true}
      )

    case Ash.create(changeset,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true},
           return_notifications?: true
         ) do
      {:ok, %RenewalCollectionAttempt{} = collection, notifications} ->
        {:ok, collection, notifications}

      {:ok, %RenewalCollectionAttempt{} = collection} ->
        {:ok, collection, []}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_collection_start_authority(subscription, attempt, collections, input) do
    previous = List.last(collections)

    with :ok <- ensure_renewal_authority(subscription, attempt),
         :ok <- ensure_bound_period_is_current(subscription, attempt),
         :ok <- ensure_due_for_collection(subscription, input.now) do
      ensure_retry_allowed(subscription, attempt, previous)
    end
  end

  defp ensure_renewal_authority(
         %Subscription{status: status} = subscription,
         %RenewalAttempt{failure_code: failure_code}
       ) do
    withdrawn? =
      status in [:canceled, :expired, :suspended] or subscription.cancel_at_period_end or
        not is_nil(subscription.canceled_at) or not is_nil(subscription.ended_at) or
        failure_code == @renewal_authority_withdrawn_code

    if withdrawn? do
      {:error, Error.new("RENEWAL_AUTHORITY_WITHDRAWN", "renewal authority is withdrawn")}
    else
      :ok
    end
  end

  defp ensure_bound_period_is_current(
         %Subscription{current_period_end_at: %DateTime{} = current_period_end},
         %RenewalAttempt{period_start_at: %DateTime{} = bound_period_start}
       ) do
    if DateTime.compare(current_period_end, bound_period_start) == :eq do
      :ok
    else
      {:error, Error.new("STALE_RECORD", "renewal attempt no longer matches the current period")}
    end
  end

  defp ensure_bound_period_is_current(_subscription, _attempt) do
    {:error, Error.new("VALIDATION_ERROR", "renewal period binding is incomplete")}
  end

  defp ensure_due_for_collection(
         %Subscription{status: :active, next_renewal_at: %DateTime{} = due_at},
         now
       ) do
    if DateTime.compare(due_at, now) in [:lt, :eq] do
      :ok
    else
      {:error, Error.new("INVALID_STATE_TRANSITION", "renewal is not due")}
    end
  end

  defp ensure_due_for_collection(
         %Subscription{status: :past_due, retry_suppressed_at: nil, next_retry_at: nil},
         _now
       ),
       do: :ok

  defp ensure_due_for_collection(
         %Subscription{
           status: :past_due,
           retry_suppressed_at: nil,
           next_retry_at: %DateTime{} = retry_at
         },
         now
       ) do
    if DateTime.compare(retry_at, now) in [:lt, :eq] do
      :ok
    else
      {:error, Error.new("INVALID_STATE_TRANSITION", "renewal retry is not due")}
    end
  end

  defp ensure_due_for_collection(_subscription, _now) do
    {:error,
     Error.new("RENEWAL_AUTHORITY_WITHDRAWN", "subscription cannot start a renewal collection")}
  end

  defp ensure_retry_allowed(%Subscription{status: :active}, _attempt, nil), do: :ok

  defp ensure_retry_allowed(
         %Subscription{status: :past_due, dunning_attempt_count: count},
         %RenewalAttempt{charged_contract_snapshot: snapshot},
         nil
       ) do
    max_retry_attempts = Map.get(snapshot, "max_retry_attempts")

    if is_integer(count) and is_integer(max_retry_attempts) and count <= max_retry_attempts do
      :ok
    else
      {:error,
       Error.new(
         "INVALID_STATE_TRANSITION",
         "renewal retry policy does not permit a collection"
       )}
    end
  end

  defp ensure_retry_allowed(
         %Subscription{status: :past_due, dunning_attempt_count: count},
         %RenewalAttempt{charged_contract_snapshot: snapshot},
         %RenewalCollectionAttempt{financial_outcome: :verified_terminal_financial_non_success}
       ) do
    max_retry_attempts = Map.get(snapshot, "max_retry_attempts")

    if is_integer(count) and count > 0 and is_integer(max_retry_attempts) and
         count <= max_retry_attempts do
      :ok
    else
      {:error,
       Error.new(
         "INVALID_STATE_TRANSITION",
         "renewal retry policy does not permit another collection"
       )}
    end
  end

  defp ensure_retry_allowed(_subscription, _attempt, _previous) do
    {:error,
     Error.new(
       "INVALID_STATE_TRANSITION",
       "a new collection requires provider-certified terminal financial non-success and current dunning authority"
     )}
  end

  defp ensure_contiguous_ordinals(collections) do
    contiguous? =
      collections
      |> Enum.with_index(1)
      |> Enum.all?(fn {%RenewalCollectionAttempt{collection_ordinal: ordinal}, expected} ->
        ordinal == expected
      end)

    if contiguous?,
      do: :ok,
      else: {:error, Error.new("STALE_RECORD", "renewal collection ordinals are not contiguous")}
  end

  defp ensure_no_success(collections) do
    if Enum.any?(collections, &(&1.financial_outcome == :verified_success)) do
      {:error,
       Error.new(
         "INVALID_STATE_TRANSITION",
         "a successful renewal cannot start another collection",
         %{already_succeeded?: true}
       )}
    else
      :ok
    end
  end

  defp active_collection?(%RenewalCollectionAttempt{financial_outcome: outcome}),
    do: outcome in [:unresolved, :requires_action]

  defp fetch_collection_transition_identity(collection_attempt_id) do
    query = """
    SELECT collection.renewal_attempt_id::text, attempt.subscription_id::text
    FROM renewal_collection_attempts collection
    JOIN renewal_attempts attempt ON attempt.id = collection.renewal_attempt_id
    WHERE collection.id = $1::text::uuid
    LIMIT 1
    """

    case Repo.query(query, [collection_attempt_id]) do
      {:ok, %{rows: [[renewal_attempt_id, subscription_id]]}} ->
        {:ok, %{renewal_attempt_id: renewal_attempt_id, subscription_id: subscription_id}}

      {:ok, %{rows: []}} ->
        {:error, Error.new("NOT_FOUND", "renewal collection was not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_transition_attempt_subscription(
         %RenewalAttempt{subscription_id: subscription_id},
         subscription_id
       ),
       do: :ok

  defp ensure_transition_attempt_subscription(_attempt, _subscription_id) do
    {:error, Error.new("STALE_RECORD", "renewal attempt changed during collection transition")}
  end

  defp ensure_transition_collection_attempt(
         %RenewalCollectionAttempt{renewal_attempt_id: renewal_attempt_id},
         %RenewalAttempt{id: renewal_attempt_id}
       ),
       do: :ok

  defp ensure_transition_collection_attempt(_collection, _attempt) do
    {:error, Error.new("STALE_RECORD", "renewal collection changed during transition")}
  end

  defp fetch_renewal_attempt(attempt_id, lock? \\ false) do
    query = RenewalAttempt |> Ash.Query.filter(expr(id == ^attempt_id))
    query = if lock?, do: Ash.Query.lock(query, "FOR UPDATE"), else: query

    case Ash.read_one(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "renewal attempt was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_collection(collection_attempt_id) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.filter(expr(id == ^collection_attempt_id))
      |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalCollectionAttempt{} = collection} -> {:ok, collection}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "renewal collection was not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_subscription(subscription_id) do
    query =
      Subscription
      |> Ash.Query.filter(expr(id == ^subscription_id))
      |> Ash.Query.lock("FOR UPDATE")

    case Ash.read_one(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %Subscription{} = subscription} -> {:ok, subscription}
      {:ok, nil} -> {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_collections(renewal_attempt_id) do
    query =
      RenewalCollectionAttempt
      |> Ash.Query.for_read(:read_for_renewal_attempt, %{renewal_attempt_id: renewal_attempt_id})

    case Ash.read(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, collections} -> {:ok, collections}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp normalize_transaction_notifications({:ok, tx_result}) when is_map(tx_result) do
    {:ok, Map.delete(tx_result, :notifications), Map.get(tx_result, :notifications, [])}
  end

  defp normalize_transaction_notifications({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp normalize_transition_notifications({:ok, transaction_result})
       when is_map(transaction_result) do
    {:ok, Map.delete(transaction_result, :notifications),
     Map.get(transaction_result, :notifications, [])}
  end

  defp normalize_transition_notifications({:error, reason}),
    do: {:error, Normalize.normalize(reason)}
end
