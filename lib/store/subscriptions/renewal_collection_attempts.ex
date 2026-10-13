defmodule Store.Subscriptions.RenewalCollectionAttempts do
  @moduledoc """
  Starts and replays durable payment collections within one bound renewal.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Catalog.Variant
  alias Store.Orders.InventoryReservation
  alias Store.Orders.InventoryAdmission.Request
  alias Store.Orders.{Order, OrderLineItem}
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade

  alias Store.Subscriptions.RenewalCollectionAttempts.{
    ClaimDispatchInput,
    FenceInput,
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

  @spec payment_intent_key(String.t()) :: String.t()
  def payment_intent_key(collection_attempt_id) when is_binary(collection_attempt_id),
    do: "renewal-collection:" <> collection_attempt_id

  @spec attach_payment_intent_for_system(PaymentIntentBindingInput.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def attach_payment_intent_for_system(%PaymentIntentBindingInput{} = input) do
    with {:ok, canonical_input} <- PaymentIntentBindingInput.new(Map.from_struct(input)),
         {:ok, collection} <-
           run_collection_transition(
             canonical_input.collection_attempt_id,
             :attach_renewal_collection_payment_intent,
             fn collection, attempt, subscription ->
               attach_payment_intent_locked(collection, attempt, subscription, canonical_input)
             end
           ),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(collection.payment_intent_id) do
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
         {:ok, collection, provider_payment_method} <-
           run_collection_transition_with_result(
             canonical_input.collection_attempt_id,
             :claim_renewal_collection_dispatch,
             fn collection, attempt, subscription ->
               claim_dispatch_locked(collection, attempt, subscription, canonical_input)
             end
           ),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(collection.payment_intent_id) do
      {:ok,
       %{
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

  @spec record_financial_outcome_for_system(RecordFinancialOutcomeInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t() | term()}
  def record_financial_outcome_for_system(%RecordFinancialOutcomeInput{} = input) do
    with {:ok, canonical_input} <- RecordFinancialOutcomeInput.new(Map.from_struct(input)) do
      run_collection_transition(
        canonical_input.collection_attempt_id,
        :record_renewal_collection_financial_outcome,
        fn collection, _attempt, _subscription ->
          record_financial_outcome_locked(collection, canonical_input)
        end
      )
    end
  end

  def record_financial_outcome_for_system(_input) do
    {:error, Error.new("VALIDATION_ERROR", "typed collection financial outcome is required")}
  end

  @spec success_handoff_for_system(String.t()) :: {:ok, map()} | {:error, Error.t() | term()}
  def success_handoff_for_system(collection_attempt_id) when is_binary(collection_attempt_id) do
    with {:ok, collection} <- fetch_collection(collection_attempt_id),
         :ok <- ensure_collection_verified_success(collection),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         {:ok, order} <- fetch_order(attempt.order_id),
         {:ok, payment_intent} <- fetch_payment_intent(collection.payment_intent_id),
         :ok <- ensure_success_handoff_identity(collection, attempt, order, payment_intent) do
      {:ok,
       %{
         order_id: order.id,
         renewal_attempt_id: attempt.id,
         collection_attempt_id: collection.id,
         payment_intent_id: payment_intent.id
       }}
    end
  end

  def success_handoff_for_system(_collection_attempt_id) do
    {:error, Error.new("VALIDATION_ERROR", "collection_attempt_id must be a UUID")}
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

  defp run_collection_transition(collection_attempt_id, flow, transition) do
    run_collection_transition(collection_attempt_id, flow, transition, false)
  end

  defp run_collection_transition_with_result(collection_attempt_id, flow, transition) do
    run_collection_transition(collection_attempt_id, flow, transition, true)
  end

  defp run_collection_transition(collection_attempt_id, flow, transition, return_result?) do
    with {:ok, observed_collection} <- fetch_collection(collection_attempt_id),
         {:ok, observed_attempt} <- fetch_renewal_attempt(observed_collection.renewal_attempt_id) do
      transaction_result =
        Repo.transaction(fn ->
          with :ok <- lock_subscription(observed_attempt.subscription_id),
               :ok <-
                 lock_renewal_attempt(
                   observed_attempt.id,
                   observed_attempt.subscription_id
                 ),
               :ok <- lock_collection(collection_attempt_id, observed_attempt.id),
               {:ok, attempt} <- fetch_renewal_attempt(observed_attempt.id),
               {:ok, collection} <- fetch_collection(collection_attempt_id),
               {:ok, subscription} <- fetch_subscription(attempt.subscription_id) do
            case transition.(collection, attempt, subscription) do
              {:ok, %RenewalCollectionAttempt{} = updated, notifications, result} ->
                %{collection: updated, notifications: notifications, result: result}

              {:ok, %RenewalCollectionAttempt{} = updated, notifications} ->
                %{collection: updated, notifications: notifications, result: nil}

              {:error, reason} ->
                Repo.rollback(reason)
            end
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
  end

  defp assign_locked_generation(collection, attempt, subscription, input) do
    with :ok <-
           SubscriptionsFacade.validate_complete_bound_renewal_attempt_for_system(attempt),
         :ok <- ensure_collection_dispatch_authority(subscription, attempt, input.now),
         :ok <- ensure_assignable_collection(collection),
         {:ok, physical?} <- physical_renewal?(attempt.variant_id) do
      case {physical?, collection.reservation_generation_id} do
        {false, nil} ->
          {:ok, collection, []}

        {false, _generation_id} ->
          {:error,
           Error.new(
             "RESERVATION_CONFLICT",
             "nonphysical renewal collection cannot own an inventory generation"
           )}

        {true, nil} ->
          with :ok <- ensure_bound_order(attempt),
               {:ok, reservation} <-
                 reserve_new_generation(collection, attempt, input.now),
               :ok <-
                 guard_collection_generation(
                   collection,
                   attempt,
                   reservation.reservation_key,
                   reservation.id
                 ),
               {:ok, updated, notifications} <-
                 update_collection(collection, :assign_reservation_generation, %{
                   reservation_generation_id: reservation.id
                 }) do
            {:ok, updated, notifications}
          end

        {true, generation_id} when is_binary(generation_id) ->
          with :ok <- ensure_bound_order(attempt),
               {:ok, reservation_key} <-
                 reservation_key_for_collection(collection, attempt),
               :ok <-
                 guard_collection_generation(
                   collection,
                   attempt,
                   reservation_key,
                   generation_id
                 ) do
            {:ok, collection, []}
          end
      end
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
      {:ok, updated, notifications}
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
         :ok <- ensure_collection_dispatch_authority(subscription, attempt, input.now),
         :ok <- Store.Payments.Providers.ensure_enabled_provider(subscription.provider),
         {:ok, provider_payment_method} <- lock_active_stored_payment_method(subscription),
         {:ok, updated, notifications} <-
           claim_collection_dispatch(collection, input.expected_epoch) do
      {:ok, updated, notifications, provider_payment_method}
    end
  end

  defp record_financial_outcome_locked(collection, input) do
    with :ok <- ensure_collection_payment_identity(collection, input.payment_intent_id),
         {:ok, payment_intent} <- fetch_payment_intent(input.payment_intent_id),
         :ok <- ensure_payment_outcome_matches_intent(payment_intent, input.financial_outcome),
         :ok <- ensure_financial_outcome_transition(collection, input.financial_outcome),
         {:ok, updated, notifications} <-
           update_collection(collection, :record_financial_outcome, %{
             financial_outcome: input.financial_outcome
           }) do
      {:ok, updated, notifications}
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

  defp ensure_collection_verified_success(%RenewalCollectionAttempt{
         financial_outcome: :verified_success,
         payment_intent_id: id
       })
       when is_binary(id),
       do: :ok

  defp ensure_collection_verified_success(_collection) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "collection has no exact verified success")}
  end

  defp ensure_success_handoff_identity(collection, attempt, order, payment_intent) do
    if collection.renewal_attempt_id == attempt.id and order.id == attempt.order_id and
         payment_intent.id == collection.payment_intent_id and
         payment_intent.order_id == order.id and payment_intent.state == :succeeded do
      :ok
    else
      {:error,
       Error.new("PAYMENT_EVENT_UNVERIFIED", "verified collection success identity conflicts")}
    end
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
      {:ok,
       %{
         rows: [[^payment_method_id, ^user_id, stored_provider, status, customer_ref, method_ref]]
       }} ->
        if stored_provider == Atom.to_string(provider) and status == "active" and
             is_binary(customer_ref) and customer_ref != "" and is_binary(method_ref) and
             method_ref != "" do
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

      {:ok, %{rows: []}} ->
        {:error,
         Error.new(
           "PAYMENT_METHOD_REQUIRED",
           "subscription has no current active provider payment method"
         )}

      {:ok, _result} ->
        {:error,
         Error.new("PAYMENT_METHOD_REQUIRED", "current provider payment method is invalid")}

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
          with {:ok, reservation_key} <- reservation_key_for_collection(collection, attempt) do
            guard_collection_generation(collection, attempt, reservation_key, generation_id)
          end
      end
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
         payment_intent.provider == subscription.provider do
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
           ),
         {:ok, updated, notifications} <-
           update_collection(collection, :fence_before_submission, %{
             dispatch_state: :not_submitted,
             fenced_through_epoch: input.expected_epoch,
             last_fence_event_id: UUIDv7.generate(),
             last_fenced_at: input.now
           }) do
      {:ok, updated, notifications}
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
         :ok <- maybe_guard_resume_generation(collection, attempt, physical?, reservation),
         {:ok, updated, notifications} <-
           update_collection(collection, :resume_after_fence, %{
             dispatch_state: :not_started,
             dispatch_epoch: input.expected_epoch + 1,
             reservation_generation_id: generation_id
           }) do
      {:ok, updated, notifications}
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

  defp ensure_assignable_collection(%RenewalCollectionAttempt{
         dispatch_state: :not_started,
         financial_outcome: :unresolved
       }),
       do: :ok

  defp ensure_assignable_collection(_collection) do
    {:error,
     Error.new(
       "INVALID_STATE_TRANSITION",
       "only an unresolved collection that has not started dispatch can own a reservation generation"
     )}
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
         :ok <- ensure_due_for_collection(subscription, now),
         :ok <- ensure_collection_retry_authority(subscription, attempt) do
      :ok
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
        with :ok <- lock_subscription(attempt.subscription_id),
             :ok <- lock_renewal_attempt(attempt.id, attempt.subscription_id),
             {:ok, locked_attempt} <- fetch_renewal_attempt(attempt.id),
             {:ok, subscription} <- fetch_subscription(attempt.subscription_id),
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
             :ok <- ensure_collection_start_authority(subscription, attempt, collections, input),
             {:ok, collection, notifications} <- create_next_collection(attempt, collections) do
          {:ok, collection, notifications}
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
         :ok <- ensure_due_for_collection(subscription, input.now),
         :ok <- ensure_retry_allowed(subscription, attempt, previous) do
      :ok
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
         "a successful renewal cannot start another collection"
       )}
    else
      :ok
    end
  end

  defp active_collection?(%RenewalCollectionAttempt{financial_outcome: outcome}),
    do: outcome in [:unresolved, :requires_action]

  defp lock_subscription(subscription_id) do
    case Repo.query("SELECT id FROM subscriptions WHERE id = $1::text::uuid FOR UPDATE", [
           subscription_id
         ]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_renewal_attempt(attempt_id, subscription_id) do
    case Repo.query(
           "SELECT id FROM renewal_attempts WHERE id = $1::text::uuid AND subscription_id = $2::text::uuid FOR UPDATE",
           [attempt_id, subscription_id]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, Error.new("STALE_RECORD", "renewal attempt changed during collection start")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_collection(collection_attempt_id, renewal_attempt_id) do
    case Repo.query(
           "SELECT id FROM renewal_collection_attempts WHERE id = $1::text::uuid AND renewal_attempt_id = $2::text::uuid FOR UPDATE",
           [collection_attempt_id, renewal_attempt_id]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, Error.new("STALE_RECORD", "renewal collection changed during transition")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_renewal_attempt(attempt_id) do
    query = RenewalAttempt |> Ash.Query.filter(expr(id == ^attempt_id))

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
    query = RenewalCollectionAttempt |> Ash.Query.filter(expr(id == ^collection_attempt_id))

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
    query = Subscription |> Ash.Query.filter(expr(id == ^subscription_id))

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
