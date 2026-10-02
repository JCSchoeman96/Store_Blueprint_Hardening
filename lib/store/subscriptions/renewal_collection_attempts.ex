defmodule Store.Subscriptions.RenewalCollectionAttempts do
  @moduledoc """
  Subscription-owned lifecycle boundary for durable renewal collection attempts.

  Dispatch transitions are epoch-fenced: only `not_started` at the expected
  epoch can be claimed or pre-submission fenced. A claim commits
  `may_have_been_reached` before any caller may submit the exact PaymentIntent.
  A fence can release only the exact active reservation generation in the same
  Repo transaction; it leaves financial outcome unresolved. Resuming a fence
  increments by exactly one and records a fresh generation when the old epoch
  owned a physical reservation.

  Financial outcomes are derived from the exact associated PaymentIntent state.
  `requires_action` is nonterminal. Verified success and verified terminal
  financial non-success are terminal and cannot regress. A `not_submitted`
  dispatch state never implies financial non-success.

  Creation locks the Subscription before its RenewalAttempt, matching existing
  renewal binding lock order. The parent lock serializes ordinal allocation; the
  partial unique index remains the durable one-active-collection authority.
  Replays return an existing active collection, and any ordinal gap or
  contradictory parent/payment evidence fails closed.
  """

  import Ash.Expr
  import Ecto.Query
  require Ash.Query

  alias Store.Orders
  alias Store.Payments.PaymentIntent
  alias Store.Repo
  alias Store.Subscriptions.{RenewalAttempt, RenewalCollectionAttempt, Subscription}
  alias Store.Support.AshNotifications
  alias Store.Support.Errors.{Error, Normalize}

  @active_financial_outcomes [:unresolved, :requires_action]
  @terminal_financial_outcomes [:verified_success, :verified_terminal_financial_non_success]

  defmodule StartInput do
    @moduledoc "Input for starting or replaying a collection under a RenewalAttempt."

    @enforce_keys [:renewal_attempt_id]
    defstruct [:renewal_attempt_id, now: nil]

    @type t :: %__MODULE__{
            renewal_attempt_id: Ecto.UUID.t(),
            now: DateTime.t() | nil
          }
  end

  defmodule ReservationGenerationInput do
    @moduledoc "Input for recording a collection's current exact reservation generation."

    @enforce_keys [:collection_attempt_id, :expected_dispatch_epoch, :reservation_generation_id]
    defstruct [:collection_attempt_id, :expected_dispatch_epoch, :reservation_generation_id]

    @type t :: %__MODULE__{
            collection_attempt_id: Ecto.UUID.t(),
            expected_dispatch_epoch: pos_integer(),
            reservation_generation_id: Ecto.UUID.t()
          }
  end

  defmodule DispatchInput do
    @moduledoc "Input for compare-and-set dispatch operations at one expected epoch."

    @enforce_keys [:collection_attempt_id, :expected_dispatch_epoch]
    defstruct [:collection_attempt_id, :expected_dispatch_epoch]

    @type t :: %__MODULE__{
            collection_attempt_id: Ecto.UUID.t(),
            expected_dispatch_epoch: pos_integer()
          }
  end

  defmodule FenceInput do
    @moduledoc "Input for fencing an epoch before provider submission."

    @enforce_keys [:collection_attempt_id, :expected_dispatch_epoch, :fence_event_id]
    defstruct [:collection_attempt_id, :expected_dispatch_epoch, :fence_event_id, :fenced_at]

    @type t :: %__MODULE__{
            collection_attempt_id: Ecto.UUID.t(),
            expected_dispatch_epoch: pos_integer(),
            fence_event_id: Ecto.UUID.t(),
            fenced_at: DateTime.t() | nil
          }
  end

  defmodule ResumeInput do
    @moduledoc "Input for advancing one successfully fenced epoch."

    @enforce_keys [:collection_attempt_id, :expected_dispatch_epoch]
    defstruct [:collection_attempt_id, :expected_dispatch_epoch, :reservation_generation_id]

    @type t :: %__MODULE__{
            collection_attempt_id: Ecto.UUID.t(),
            expected_dispatch_epoch: pos_integer(),
            reservation_generation_id: Ecto.UUID.t() | nil
          }
  end

  defmodule AttachPaymentIntentInput do
    @moduledoc "Input for attaching the exact deterministic PaymentIntent to a collection."

    @enforce_keys [:collection_attempt_id, :payment_intent_id]
    defstruct [:collection_attempt_id, :payment_intent_id]

    @type t :: %__MODULE__{
            collection_attempt_id: Ecto.UUID.t(),
            payment_intent_id: Ecto.UUID.t()
          }
  end

  defmodule RefreshFinancialOutcomeInput do
    @moduledoc "Input for refreshing a collection from its exact PaymentIntent evidence."

    @enforce_keys [:collection_attempt_id]
    defstruct [:collection_attempt_id]

    @type t :: %__MODULE__{collection_attempt_id: Ecto.UUID.t()}
  end

  @spec start_for_system(StartInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def start_for_system(%StartInput{} = input) do
    now = input.now || DateTime.utc_now() |> DateTime.truncate(:microsecond)

    if valid_uuid?(input.renewal_attempt_id) and match?(%DateTime{}, now) do
      transact(fn -> start_in_transaction(input.renewal_attempt_id, now) end)
    else
      {:error, validation_error("renewal_attempt_id and now must be valid typed values")}
    end
  end

  def start_for_system(_input),
    do: {:error, validation_error("typed RenewalCollectionAttempts.StartInput is required")}

  @spec assign_reservation_generation_for_system(ReservationGenerationInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def assign_reservation_generation_for_system(%ReservationGenerationInput{} = input) do
    with :ok <-
           valid_collection_epoch_input(
             input.collection_attempt_id,
             input.expected_dispatch_epoch
           ),
         true <- valid_uuid?(input.reservation_generation_id) do
      transact(fn -> assign_generation_in_transaction(input) end)
    else
      _ -> {:error, validation_error("reservation generation input is invalid")}
    end
  end

  def assign_reservation_generation_for_system(_input),
    do: {:error, validation_error("typed reservation generation input is required")}

  @spec claim_dispatch_for_system(DispatchInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def claim_dispatch_for_system(%DispatchInput{} = input) do
    case valid_collection_epoch_input(
           input.collection_attempt_id,
           input.expected_dispatch_epoch
         ) do
      :ok -> transact(fn -> claim_dispatch_in_transaction(input) end)
      {:error, _error} -> {:error, validation_error("dispatch claim input is invalid")}
    end
  end

  def claim_dispatch_for_system(_input),
    do: {:error, validation_error("typed dispatch claim input is required")}

  @spec fence_before_submission_for_system(FenceInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def fence_before_submission_for_system(%FenceInput{} = input) do
    fenced_at = input.fenced_at || DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with :ok <-
           valid_collection_epoch_input(
             input.collection_attempt_id,
             input.expected_dispatch_epoch
           ),
         true <- valid_uuid?(input.fence_event_id),
         true <- match?(%DateTime{}, fenced_at) do
      transact(fn -> fence_in_transaction(%{input | fenced_at: fenced_at}) end)
    else
      _ -> {:error, validation_error("pre-submission fence input is invalid")}
    end
  end

  def fence_before_submission_for_system(_input),
    do: {:error, validation_error("typed fence input is required")}

  @spec resume_after_fence_for_system(ResumeInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def resume_after_fence_for_system(%ResumeInput{} = input) do
    with :ok <-
           valid_collection_epoch_input(
             input.collection_attempt_id,
             input.expected_dispatch_epoch
           ),
         true <-
           is_nil(input.reservation_generation_id) or valid_uuid?(input.reservation_generation_id) do
      transact(fn -> resume_in_transaction(input) end)
    else
      _ -> {:error, validation_error("resume input is invalid")}
    end
  end

  def resume_after_fence_for_system(_input),
    do: {:error, validation_error("typed resume input is required")}

  @spec attach_payment_intent_for_system(AttachPaymentIntentInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def attach_payment_intent_for_system(%AttachPaymentIntentInput{} = input) do
    if valid_uuid?(input.collection_attempt_id) and valid_uuid?(input.payment_intent_id) do
      transact(fn -> attach_payment_intent_in_transaction(input) end)
    else
      {:error, validation_error("PaymentIntent association input is invalid")}
    end
  end

  def attach_payment_intent_for_system(_input),
    do: {:error, validation_error("typed PaymentIntent association input is required")}

  @spec refresh_financial_outcome_for_system(RefreshFinancialOutcomeInput.t()) ::
          {:ok, RenewalCollectionAttempt.t()} | {:error, Error.t()}
  def refresh_financial_outcome_for_system(%RefreshFinancialOutcomeInput{} = input) do
    if valid_uuid?(input.collection_attempt_id) do
      transact(fn -> refresh_outcome_in_transaction(input.collection_attempt_id) end)
    else
      {:error, validation_error("collection_attempt_id must be a UUID")}
    end
  end

  def refresh_financial_outcome_for_system(_input),
    do: {:error, validation_error("typed financial outcome refresh input is required")}

  @spec payment_intent_key(Ecto.UUID.t()) :: String.t()
  def payment_intent_key(collection_attempt_id) when is_binary(collection_attempt_id),
    do: "renewal-collection:" <> collection_attempt_id

  def payment_intent_key(_collection_attempt_id),
    do: raise(ArgumentError, "collection_attempt_id must be a UUID")

  defp start_in_transaction(renewal_attempt_id, now) do
    with {:ok, initial_attempt} <- fetch_renewal_attempt(renewal_attempt_id),
         :ok <- lock_subscription(initial_attempt.subscription_id),
         :ok <- lock_renewal_attempt(initial_attempt.id, initial_attempt.subscription_id),
         {:ok, attempt} <- fetch_renewal_attempt(renewal_attempt_id),
         :ok <- ensure_bound_attempt(attempt),
         collections <- lock_collections(attempt.id),
         :ok <- ensure_contiguous_ordinals(collections),
         {:ok, collection_or_new} <- collection_for_start(attempt, collections, now) do
      case collection_or_new do
        {:existing, collection} -> collection
        {:new, ordinal} -> create_collection!(attempt.id, ordinal)
      end
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp collection_for_start(_attempt, [], _now), do: {:ok, {:new, 1}}

  defp collection_for_start(%RenewalAttempt{} = attempt, collections, now) do
    active = Enum.filter(collections, &(&1.financial_outcome in @active_financial_outcomes))
    latest = List.last(collections)

    cond do
      Enum.any?(collections, &(&1.financial_outcome == :verified_success)) ->
        {:error, invalid_transition("a successful collection permanently closes this renewal")}

      length(active) > 1 ->
        {:error, invalid_transition("multiple active collections contradict durable authority")}

      active != [] and hd(active).id != latest.id ->
        {:error, invalid_transition("an older active collection blocks ordinal allocation")}

      active != [] ->
        {:ok, {:existing, latest}}

      latest.financial_outcome == :verified_terminal_financial_non_success ->
        with :ok <- ensure_dunning_retry_permitted(attempt, now) do
          {:ok, {:new, latest.collection_ordinal + 1}}
        end

      true ->
        {:error, invalid_transition("collection outcome does not permit another ordinal")}
    end
  end

  defp ensure_bound_attempt(%RenewalAttempt{} = attempt) do
    bound? =
      [
        attempt.charged_contract_version == 1,
        is_binary(attempt.plan_revision_id),
        is_binary(attempt.variant_id),
        positive_integer?(attempt.quantity),
        non_negative_integer?(attempt.amount_minor),
        valid_currency?(attempt.currency),
        positive_integer?(attempt.expected_subscription_version),
        is_map(attempt.charged_contract_snapshot)
      ]
      |> Enum.all?(& &1)

    if bound?,
      do: :ok,
      else: {:error, invalid_transition("collection requires a complete bound RenewalAttempt")}
  end

  defp ensure_dunning_retry_permitted(%RenewalAttempt{} = attempt, now) do
    with {:ok, %Subscription{} = subscription} <- fetch_subscription(attempt.subscription_id),
         true <- subscription.status == :past_due,
         true <- is_nil(subscription.retry_suppressed_at),
         true <- dunning_count_within_bound_policy?(subscription, attempt),
         true <- retry_is_due?(subscription.next_retry_at, now) do
      :ok
    else
      _ ->
        {:error, invalid_transition("current dunning state does not permit another collection")}
    end
  end

  defp dunning_count_within_bound_policy?(subscription, attempt) do
    count = subscription.dunning_attempt_count || 0
    maximum = Map.get(attempt.charged_contract_snapshot, "max_retry_attempts")

    is_integer(count) and count >= 0 and is_integer(maximum) and count < maximum
  end

  defp retry_is_due?(nil, _now), do: true

  defp retry_is_due?(%DateTime{} = next_retry_at, now),
    do: DateTime.compare(next_retry_at, now) in [:lt, :eq]

  defp retry_is_due?(_next_retry_at, _now), do: false

  defp assign_generation_in_transaction(input) do
    with {:ok, collection} <- lock_collection(input.collection_attempt_id),
         :ok <- ensure_epoch(collection, input.expected_dispatch_epoch),
         :ok <- ensure_unstarted(collection),
         :ok <- ensure_generation_assignment_allowed(collection, input.reservation_generation_id),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         :ok <-
           ensure_exact_active_generation(attempt, collection, input.reservation_generation_id),
         {:ok, collection} <- assign_generation(collection, input) do
      collection
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp assign_generation(
         %RenewalCollectionAttempt{reservation_generation_id: generation} = collection,
         input
       )
       when generation == input.reservation_generation_id,
       do: {:ok, collection}

  defp assign_generation(
         %RenewalCollectionAttempt{reservation_generation_id: nil} = collection,
         input
       ) do
    update_collection!(collection, :assign_reservation_generation, %{
      expected_dispatch_epoch: input.expected_dispatch_epoch,
      reservation_generation_id: input.reservation_generation_id
    })
  end

  defp assign_generation(_collection, _input),
    do: {:error, invalid_transition("collection already owns a different reservation generation")}

  defp ensure_generation_assignment_allowed(
         %RenewalCollectionAttempt{reservation_generation_id: nil},
         _generation_id
       ),
       do: :ok

  defp ensure_generation_assignment_allowed(
         %RenewalCollectionAttempt{reservation_generation_id: generation_id},
         generation_id
       ),
       do: :ok

  defp ensure_generation_assignment_allowed(_collection, _generation_id),
    do: {:error, invalid_transition("collection already owns a different reservation generation")}

  defp claim_dispatch_in_transaction(input) do
    with {:ok, collection} <- lock_collection(input.collection_attempt_id),
         :ok <- ensure_epoch(collection, input.expected_dispatch_epoch),
         :ok <- ensure_unstarted(collection),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         :ok <- ensure_current_generation_active(attempt, collection),
         true <- is_binary(collection.payment_intent_id),
         {:ok, claimed} <-
           update_collection!(collection, :claim_dispatch, %{
             expected_dispatch_epoch: input.expected_dispatch_epoch
           }) do
      claimed
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      false -> Repo.rollback(invalid_transition("dispatch requires its exact PaymentIntent"))
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp fence_in_transaction(%FenceInput{} = input) do
    with {:ok, collection} <- lock_collection(input.collection_attempt_id),
         :ok <- ensure_epoch(collection, input.expected_dispatch_epoch),
         {:ok, result} <- fence_or_replay(collection, input) do
      result
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp fence_or_replay(
         %RenewalCollectionAttempt{
           dispatch_state: :not_submitted,
           fenced_through_epoch: epoch,
           last_fence_event_id: event_id
         } = collection,
         %FenceInput{expected_dispatch_epoch: epoch, fence_event_id: event_id}
       ),
       do: {:ok, collection}

  defp fence_or_replay(
         %RenewalCollectionAttempt{dispatch_state: :not_started} = collection,
         input
       ) do
    case release_exact_generation(collection) do
      :ok ->
        update_collection!(collection, :fence_before_submission, %{
          expected_dispatch_epoch: input.expected_dispatch_epoch,
          fence_event_id: input.fence_event_id,
          fenced_at: input.fenced_at
        })

      {:error, _error} = error ->
        error
    end
  end

  defp fence_or_replay(%RenewalCollectionAttempt{dispatch_state: :may_have_been_reached}, _input),
    do: {:error, invalid_transition("a possibly reached provider request cannot be fenced")}

  defp fence_or_replay(_collection, _input),
    do: {:error, stale_record("dispatch fence does not match the current epoch evidence")}

  defp release_exact_generation(%RenewalCollectionAttempt{reservation_generation_id: nil}),
    do: :ok

  defp release_exact_generation(%RenewalCollectionAttempt{} = collection) do
    with {:ok, %RenewalAttempt{} = attempt} <-
           fetch_renewal_attempt(collection.renewal_attempt_id),
         true <- is_binary(attempt.order_id) and is_binary(attempt.variant_id),
         key <- reservation_key(attempt, collection),
         {:ok, %{reservation: %{state: :cancelled}, changed?: true}} <-
           Orders.release_exact_generation(attempt.order_id, attempt.variant_id, key) do
      :ok
    else
      _ ->
        {:error,
         reservation_conflict("exact active reservation generation could not be released")}
    end
  end

  defp ensure_current_generation_active(_attempt, %RenewalCollectionAttempt{
         reservation_generation_id: nil
       }),
       do: :ok

  defp ensure_current_generation_active(attempt, %RenewalCollectionAttempt{} = collection),
    do:
      ensure_exact_active_generation(
        attempt,
        collection,
        collection.reservation_generation_id
      )

  defp ensure_exact_active_generation(
         %RenewalAttempt{} = attempt,
         %RenewalCollectionAttempt{} = collection,
         generation_id
       ) do
    with true <- is_binary(attempt.order_id) and is_binary(attempt.variant_id),
         key <- reservation_key(attempt, collection, generation_id),
         {:ok, {:found, facts}} <-
           Orders.recover_exact_generation(attempt.order_id, attempt.variant_id, key),
         true <- exact_active_generation_facts?(facts, attempt, key) do
      :ok
    else
      _ ->
        {:error,
         reservation_conflict(
           "exact active reservation generation evidence is missing or contradictory"
         )}
    end
  end

  defp exact_active_generation_facts?(facts, attempt, expected_key) when is_map(facts) do
    Map.get(facts, :reservation_key) == expected_key and
      Map.get(facts, :order_id) == attempt.order_id and
      Map.get(facts, :variant_id) == attempt.variant_id and
      Map.get(facts, :quantity) == attempt.quantity and
      Map.get(facts, :state) == :active
  end

  defp exact_active_generation_facts?(_facts, _attempt, _expected_key), do: false

  defp resume_in_transaction(input) do
    with {:ok, collection} <- lock_collection(input.collection_attempt_id),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         {:ok, resumed} <- resume_or_replay(collection, attempt, input) do
      resumed
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp resume_or_replay(
         %RenewalCollectionAttempt{
           dispatch_state: :not_started,
           dispatch_epoch: epoch,
           fenced_through_epoch: fenced,
           reservation_generation_id: generation
         } = collection,
         %RenewalAttempt{} = attempt,
         %ResumeInput{expected_dispatch_epoch: expected, reservation_generation_id: generation}
       )
       when epoch == expected + 1 and fenced == expected,
       do: replay_resumed_collection(collection, attempt, generation)

  defp resume_or_replay(%RenewalCollectionAttempt{} = collection, attempt, input) do
    cond do
      collection.dispatch_epoch != input.expected_dispatch_epoch ->
        {:error, stale_record("resume expected a stale dispatch epoch")}

      collection.dispatch_state != :not_submitted or
          collection.fenced_through_epoch != input.expected_dispatch_epoch ->
        {:error, invalid_transition("resume requires a successful pre-submission fence")}

      collection.financial_outcome != :unresolved ->
        {:error, invalid_transition("only unresolved financial outcome can resume after a fence")}

      not resume_generation_valid?(
        collection.reservation_generation_id,
        input.reservation_generation_id
      ) ->
        {:error, invalid_transition("resume requires a fresh exact reservation generation")}

      true ->
        with :ok <-
               ensure_resume_generation_active(
                 attempt,
                 collection,
                 input.reservation_generation_id
               ) do
          update_collection!(collection, :resume_after_fence, %{
            expected_dispatch_epoch: input.expected_dispatch_epoch,
            next_dispatch_epoch: input.expected_dispatch_epoch + 1,
            reservation_generation_id: input.reservation_generation_id
          })
        end
    end
  end

  defp resume_generation_valid?(nil, nil), do: true

  defp resume_generation_valid?(previous, next) when is_binary(previous),
    do: is_binary(next) and previous != next

  defp resume_generation_valid?(_previous, _next), do: false

  defp replay_resumed_collection(collection, _attempt, nil),
    do: {:ok, collection}

  defp replay_resumed_collection(collection, attempt, generation_id) do
    with :ok <- ensure_exact_active_generation(attempt, collection, generation_id) do
      {:ok, collection}
    end
  end

  defp ensure_resume_generation_active(_attempt, _collection, nil), do: :ok

  defp ensure_resume_generation_active(attempt, collection, generation_id),
    do: ensure_exact_active_generation(attempt, collection, generation_id)

  defp attach_payment_intent_in_transaction(input) do
    with {:ok, collection} <- lock_collection(input.collection_attempt_id),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         :ok <- validate_payment_intent(attempt, collection, input.payment_intent_id),
         {:ok, attached} <- attach_or_replay(collection, input.payment_intent_id) do
      attached
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp validate_payment_intent(%RenewalAttempt{order_id: order_id}, collection, payment_intent_id)
       when is_binary(order_id) do
    key = payment_intent_key(collection.id)

    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(id == ^payment_intent_id and order_id == ^order_id and payment_intent_key == ^key)
      )

    case Ash.read_one(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, %PaymentIntent{}} ->
        :ok

      {:ok, nil} ->
        {:error, invalid_transition("PaymentIntent identity does not match this collection")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp validate_payment_intent(_attempt, _collection, _payment_intent_id),
    do: {:error, invalid_transition("bound RenewalAttempt has no exact Order for PaymentIntent")}

  defp attach_or_replay(
         %RenewalCollectionAttempt{payment_intent_id: payment_intent_id} = collection,
         payment_intent_id
       ),
       do: {:ok, collection}

  defp attach_or_replay(
         %RenewalCollectionAttempt{payment_intent_id: nil} = collection,
         payment_intent_id
       ) do
    if collection.dispatch_state == :not_started do
      update_collection!(collection, :attach_payment_intent, %{
        payment_intent_id: payment_intent_id
      })
    else
      {:error, invalid_transition("PaymentIntent association is immutable after dispatch claim")}
    end
  end

  defp attach_or_replay(_collection, _payment_intent_id),
    do:
      {:error, invalid_transition("collection is already associated with another PaymentIntent")}

  defp refresh_outcome_in_transaction(collection_attempt_id) do
    with {:ok, collection} <- lock_collection(collection_attempt_id),
         {:ok, attempt} <- fetch_renewal_attempt(collection.renewal_attempt_id),
         {:ok, intent} <- fetch_associated_payment_intent(attempt, collection),
         {:ok, target_outcome} <- verified_outcome(intent),
         {:ok, updated} <- update_outcome(collection, target_outcome) do
      updated
    else
      {:error, %Error{} = error} -> Repo.rollback(error)
      {:error, reason} -> Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp fetch_associated_payment_intent(
         %RenewalAttempt{order_id: order_id},
         %RenewalCollectionAttempt{payment_intent_id: payment_intent_id} = collection
       )
       when is_binary(order_id) and is_binary(payment_intent_id) do
    key = payment_intent_key(collection.id)

    query =
      PaymentIntent
      |> Ash.Query.filter(
        expr(id == ^payment_intent_id and order_id == ^order_id and payment_intent_key == ^key)
      )

    case Ash.read_one(query, domain: Store.Payments, authorize?: false, context: %{system?: true}) do
      {:ok, %PaymentIntent{} = payment_intent} ->
        {:ok, payment_intent}

      {:ok, nil} ->
        {:error, invalid_transition("associated PaymentIntent evidence is contradictory")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_associated_payment_intent(_attempt, _collection),
    do: {:error, invalid_transition("collection has no exact PaymentIntent association")}

  defp verified_outcome(%PaymentIntent{state: :requires_action}), do: {:ok, :requires_action}
  defp verified_outcome(%PaymentIntent{state: :succeeded}), do: {:ok, :verified_success}

  defp verified_outcome(%PaymentIntent{state: :failed}),
    do: {:ok, :verified_terminal_financial_non_success}

  defp verified_outcome(%PaymentIntent{}), do: {:ok, :unresolved}

  defp update_outcome(%RenewalCollectionAttempt{financial_outcome: target} = collection, target),
    do: {:ok, collection}

  defp update_outcome(%RenewalCollectionAttempt{} = collection, target) do
    cond do
      collection.financial_outcome in @terminal_financial_outcomes ->
        {:error,
         invalid_transition(
           "terminal financial outcome conflicts with exact PaymentIntent evidence"
         )}

      target == :unresolved ->
        {:ok, collection}

      collection.dispatch_state != :may_have_been_reached ->
        {:error, invalid_transition("financial evidence requires a claimed dispatch epoch")}

      not valid_financial_transition?(collection.financial_outcome, target) ->
        {:error, invalid_transition("terminal financial outcome cannot regress or be replaced")}

      true ->
        update_collection!(collection, :record_financial_outcome, %{
          expected_financial_outcome: collection.financial_outcome,
          financial_outcome: target
        })
    end
  end

  defp valid_financial_transition?(:unresolved, outcome),
    do: outcome in [:requires_action | @terminal_financial_outcomes]

  defp valid_financial_transition?(:requires_action, outcome),
    do: outcome in @terminal_financial_outcomes

  defp valid_financial_transition?(outcome, outcome), do: true
  defp valid_financial_transition?(_from, _to), do: false

  defp create_collection!(renewal_attempt_id, ordinal) do
    RenewalCollectionAttempt
    |> Ash.Changeset.for_create(
      :create,
      %{renewal_attempt_id: renewal_attempt_id, collection_ordinal: ordinal},
      context: %{system?: true}
    )
    |> Ash.create(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %RenewalCollectionAttempt{} = collection, notifications} ->
        collect_notifications(notifications)
        collection

      {:ok, %RenewalCollectionAttempt{} = collection} ->
        collection

      {:error, reason} ->
        Repo.rollback(Normalize.normalize(reason))
    end
  end

  defp update_collection!(collection, action, attrs) do
    collection
    |> Ash.Changeset.for_update(action, attrs, context: %{system?: true})
    |> Ash.update(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true},
      return_notifications?: true
    )
    |> case do
      {:ok, %RenewalCollectionAttempt{} = updated, notifications} ->
        collect_notifications(notifications)
        {:ok, updated}

      {:ok, %RenewalCollectionAttempt{} = updated} ->
        {:ok, updated}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp lock_subscription(subscription_id) do
    case Repo.query("SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE", [
           Ecto.UUID.dump!(subscription_id)
         ]) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, Error.new("SUBSCRIPTION_NOT_FOUND", "subscription not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp lock_renewal_attempt(renewal_attempt_id, subscription_id) do
    case Repo.query(
           "SELECT id FROM renewal_attempts WHERE id = $1 AND subscription_id = $2 FOR UPDATE",
           [Ecto.UUID.dump!(renewal_attempt_id), Ecto.UUID.dump!(subscription_id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, Error.new("NOT_FOUND", "RenewalAttempt not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp lock_collections(renewal_attempt_id) do
    Repo.all(
      from(collection in RenewalCollectionAttempt,
        where: collection.renewal_attempt_id == ^renewal_attempt_id,
        order_by: [asc: collection.collection_ordinal],
        lock: "FOR UPDATE"
      )
    )
  end

  defp ensure_contiguous_ordinals(collections) do
    actual = Enum.map(collections, & &1.collection_ordinal)
    expected = if actual == [], do: [], else: Enum.to_list(1..length(actual))

    if actual == expected,
      do: :ok,
      else: {:error, invalid_transition("collection ordinal history contains a gap or duplicate")}
  end

  defp fetch_renewal_attempt(id) do
    query = RenewalAttempt |> Ash.Query.filter(expr(id == ^id))

    case Ash.read_one(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "RenewalAttempt not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_subscription(id) do
    query = Subscription |> Ash.Query.filter(expr(id == ^id))

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

  defp lock_collection(id) do
    case Repo.query("SELECT id FROM renewal_collection_attempts WHERE id = $1 FOR UPDATE", [
           Ecto.UUID.dump!(id)
         ]) do
      {:ok, %{num_rows: 1}} ->
        fetch_collection(id)

      {:ok, %{num_rows: 0}} ->
        {:error, Error.new("NOT_FOUND", "RenewalCollectionAttempt not found")}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  defp fetch_collection(id) do
    query = RenewalCollectionAttempt |> Ash.Query.filter(expr(id == ^id))

    case Ash.read_one(query,
           domain: Store.Subscriptions,
           authorize?: false,
           context: %{system?: true}
         ) do
      {:ok, %RenewalCollectionAttempt{} = collection} -> {:ok, collection}
      {:ok, nil} -> {:error, Error.new("NOT_FOUND", "RenewalCollectionAttempt not found")}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp ensure_epoch(collection, expected_epoch) do
    if collection.dispatch_epoch == expected_epoch,
      do: :ok,
      else: {:error, stale_record("dispatch operation expected a stale epoch")}
  end

  defp ensure_unstarted(%RenewalCollectionAttempt{dispatch_state: :not_started}), do: :ok

  defp ensure_unstarted(_collection),
    do: {:error, invalid_transition("dispatch operation requires not_started state")}

  defp valid_collection_epoch_input(id, epoch) do
    if valid_uuid?(id) and is_integer(epoch) and epoch > 0,
      do: :ok,
      else: {:error, validation_error("collection ID and positive expected epoch are required")}
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_currency?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Z]{3}$/, value)

  defp valid_currency?(_value), do: false

  defp reservation_key(attempt, collection),
    do: reservation_key(attempt, collection, collection.reservation_generation_id)

  defp reservation_key(attempt, collection, generation_id) do
    "order:#{attempt.order_id}:sku:#{attempt.variant_id}:renewal_collection:#{collection.id}:generation:#{generation_id}"
  end

  defp transact(fun) do
    notification_key = {__MODULE__, :notifications, make_ref()}
    Process.put(notification_key, [])

    try do
      case Repo.transaction(fn ->
             result = fun.()
             {result, Process.get(notification_key, [])}
           end) do
        {:ok, {result, notifications}} ->
          AshNotifications.notify_post_commit(notifications, context: %{domain: :subscriptions})
          {:ok, result}

        {:error, reason} ->
          {:error, Normalize.normalize(reason)}
      end
    rescue
      _error -> {:error, Error.new("INTERNAL_ERROR", "renewal collection transaction failed")}
    after
      Process.delete(notification_key)
    end
  end

  defp collect_notifications(notifications) when is_list(notifications) do
    key =
      Process.get_keys()
      |> Enum.find(fn
        {__MODULE__, :notifications, _reference} -> true
        _ -> false
      end)

    if key do
      Process.put(key, Process.get(key, []) ++ notifications)
    end

    :ok
  end

  defp invalid_transition(message), do: Error.new("INVALID_STATE_TRANSITION", message)
  defp stale_record(message), do: Error.new("STALE_RECORD", message)
  defp reservation_conflict(message), do: Error.new("RESERVATION_CONFLICT", message)
  defp validation_error(message), do: Error.new("VALIDATION_ERROR", message)
end
