defmodule Store.Subscriptions.RenewalCollectionAttempts do
  @moduledoc """
  Starts and replays durable payment collections within one bound renewal.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Repo
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.Subscriptions.RenewalCollectionAttempts.StartInput

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
end
