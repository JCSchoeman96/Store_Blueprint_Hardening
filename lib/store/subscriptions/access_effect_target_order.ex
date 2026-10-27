defmodule Store.Subscriptions.AccessEffectTargetOrder do
  @moduledoc false

  alias Store.Subscriptions.{AccessEffect, PlanRevision, RenewalAttempt, Subscription}
  alias Store.Subscriptions.RenewalCollectionAttempts
  alias Store.Support.Errors.Error

  @type target_evidence :: %{
          disposition: :effective | :non_effective,
          entitlement_kind: atom() | nil,
          entitlement_scope_key: String.t() | nil,
          valid_from_at: DateTime.t() | nil,
          valid_until_at: DateTime.t() | nil,
          source_order_line_item_id: Ecto.UUID.t(),
          contract_change_id: Ecto.UUID.t() | nil,
          plan_revision_id: Ecto.UUID.t()
        }

  @non_effective_statuses [:suspended, :canceled]

  @spec evidence_from_access_effect(AccessEffect.t()) :: target_evidence()
  def evidence_from_access_effect(%AccessEffect{} = effect) do
    %{
      disposition: effect.disposition,
      entitlement_kind: effect.entitlement_kind,
      entitlement_scope_key: effect.entitlement_scope_key,
      valid_from_at: effect.valid_from_at,
      valid_until_at: effect.valid_until_at,
      source_order_line_item_id: effect.source_order_line_item_id,
      contract_change_id: effect.contract_change_id,
      plan_revision_id: effect.plan_revision_id
    }
  end

  @spec target_evidence_equal?(target_evidence(), target_evidence()) :: boolean()
  def target_evidence_equal?(left, right) when is_map(left) and is_map(right) do
    left.disposition == right.disposition and
      left.entitlement_kind == right.entitlement_kind and
      left.entitlement_scope_key == right.entitlement_scope_key and
      datetimes_equal?(left.valid_from_at, right.valid_from_at) and
      datetimes_equal?(left.valid_until_at, right.valid_until_at) and
      left.source_order_line_item_id == right.source_order_line_item_id and
      left.contract_change_id == right.contract_change_id and
      left.plan_revision_id == right.plan_revision_id
  end

  @spec covered?(AccessEffect.t(), target_evidence()) :: boolean()
  def covered?(%AccessEffect{} = effect, derived) do
    target_evidence_equal?(evidence_from_access_effect(effect), derived)
  end

  @spec derive_current_target(Subscription.t(), PlanRevision.t() | nil) ::
          {:ok, target_evidence()} | {:error, Error.t()}
  def derive_current_target(%Subscription{} = subscription, plan_revision) do
    cond do
      subscription.status == :active ->
        derive_effective_target(subscription, plan_revision)

      subscription.status == :past_due ->
        {:error,
         Error.new(
           "TARGET_ORDER_UNPROVABLE",
           "past_due target derivation requires the bound dunning RenewalAttempt"
         )}

      subscription.status in @non_effective_statuses ->
        {:ok, non_effective_evidence(subscription)}

      true ->
        unsupported_state(subscription.status)
    end
  end

  @spec derive_keep_during_grace_target(
          Subscription.t(),
          RenewalAttempt.t(),
          PlanRevision.t()
        ) :: {:ok, target_evidence()} | {:error, Error.t()}
  def derive_keep_during_grace_target(
        %Subscription{} = subscription,
        %RenewalAttempt{} = attempt,
        %PlanRevision{} = funded_revision
      ) do
    with :ok <- prove_past_due_keep_grace_episode(subscription, attempt, funded_revision),
         {:ok, kind, scope} <- funded_entitlement_pair(funded_revision) do
      keep_during_grace_target_evidence(subscription, kind, scope)
    end
  end

  @spec keep_during_grace_establish_attrs(Subscription.t(), target_evidence()) :: map()
  def keep_during_grace_establish_attrs(%Subscription{} = subscription, target)
      when is_map(target) do
    %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: target.disposition,
      entitlement_kind: target.entitlement_kind,
      entitlement_scope_key: target.entitlement_scope_key,
      valid_from_at: target.valid_from_at,
      valid_until_at: target.valid_until_at,
      source_order_line_item_id: target.source_order_line_item_id,
      contract_change_id: target.contract_change_id,
      plan_revision_id: target.plan_revision_id
    }
  end

  @spec charged_renewal_establish_attrs(
          Subscription.t(),
          RenewalAttempt.t(),
          map()
        ) :: map()
  def charged_renewal_establish_attrs(
        %Subscription{} = subscription,
        %RenewalAttempt{} = attempt,
        target
      )
      when is_map(target) do
    pair? =
      pair_present?(Map.get(target, :entitlement_kind), Map.get(target, :entitlement_scope_key))

    %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: :effective,
      entitlement_kind: Map.get(target, :entitlement_kind),
      entitlement_scope_key: Map.get(target, :entitlement_scope_key),
      valid_from_at: if(pair?, do: attempt.period_start_at, else: nil),
      valid_until_at: attempt.period_end_at,
      source_order_line_item_id: subscription.source_order_line_item_id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: attempt.plan_revision_id
    }
  end

  @spec immediate_cancellation_establish_attrs(Subscription.t()) :: map()
  def immediate_cancellation_establish_attrs(%Subscription{} = subscription) do
    %{
      subscription_id: subscription.id,
      source_version: subscription.aggregate_version,
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: subscription.source_order_line_item_id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: subscription.current_plan_revision_id
    }
  end

  defp derive_effective_target(%Subscription{} = subscription, %PlanRevision{} = revision) do
    with :ok <- require_uuid(subscription.source_order_line_item_id, "source order line item"),
         :ok <- require_uuid(subscription.current_plan_revision_id, "plan revision"),
         :ok <- require_period_end(subscription.current_period_end_at),
         {:ok, kind, scope} <- revision_entitlement_pair(revision) do
      effective_target_evidence(subscription, kind, scope)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp derive_effective_target(%Subscription{}, nil), do: missing_plan_revision_error()

  defp prove_past_due_keep_grace_episode(
         %Subscription{} = subscription,
         %RenewalAttempt{} = attempt,
         %PlanRevision{} = funded_revision
       ) do
    with :ok <- require_past_due_status(subscription),
         :ok <- require_bound_dunning_pointer(subscription, attempt),
         :ok <- prove_bound_dunning_attempt(subscription, attempt),
         :ok <- require_past_due_since_at(subscription),
         :ok <- require_failed_payment_boundary(subscription),
         :ok <- require_uuid(subscription.source_order_line_item_id, "source order line item"),
         :ok <- require_uuid(subscription.current_plan_revision_id, "plan revision"),
         :ok <- require_funded_revision_identity(subscription, funded_revision) do
      :ok
    end
  end

  defp require_past_due_status(%Subscription{status: :past_due}), do: :ok

  defp require_past_due_status(%Subscription{}) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "keep_during_grace target derivation requires a past_due Subscription"
     )}
  end

  defp require_bound_dunning_pointer(
         %Subscription{current_dunning_renewal_attempt_id: attempt_id},
         %RenewalAttempt{id: attempt_id}
       )
       when is_binary(attempt_id),
       do: :ok

  defp require_bound_dunning_pointer(%Subscription{current_dunning_renewal_attempt_id: nil}, _) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "bound dunning RenewalAttempt pointer is required for keep_during_grace derivation"
     )}
  end

  defp require_bound_dunning_pointer(%Subscription{}, %RenewalAttempt{}) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "bound dunning RenewalAttempt pointer does not match the locked attempt"
     )}
  end

  defp require_past_due_since_at(%Subscription{past_due_since_at: %DateTime{}}), do: :ok

  defp require_past_due_since_at(%Subscription{}) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "past_due_since_at is required for keep_during_grace target derivation"
     )}
  end

  defp require_funded_revision_identity(
         %Subscription{current_plan_revision_id: revision_id},
         %PlanRevision{id: funded_id}
       )
       when is_binary(revision_id) and revision_id == funded_id,
       do: :ok

  defp require_funded_revision_identity(%Subscription{}, %PlanRevision{}) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "funded PlanRevision does not match the Subscription current plan revision"
     )}
  end

  defp prove_bound_dunning_attempt(%Subscription{} = subscription, %RenewalAttempt{} = attempt) do
    with :ok <-
           RenewalCollectionAttempts.ensure_current_dunning_attempt_owner(subscription, attempt),
         true <- bound_renewal_occurrence?(subscription, attempt) do
      :ok
    else
      false ->
        {:error,
         Error.new(
           "TARGET_ORDER_UNPROVABLE",
           "RenewalAttempt does not match the locked Subscription period"
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp bound_renewal_occurrence?(
         %Subscription{
           id: subscription_id,
           current_period_end_at: %DateTime{} = period_start_at
         },
         %RenewalAttempt{
           subscription_id: attempt_subscription_id,
           period_start_at: %DateTime{} = attempt_period_start_at
         }
       ) do
    subscription_id == attempt_subscription_id and
      DateTime.compare(period_start_at, attempt_period_start_at) == :eq
  end

  defp bound_renewal_occurrence?(_, _), do: false

  defp keep_during_grace_target_evidence(%Subscription{} = subscription, kind, scope)
       when not is_nil(kind) and not is_nil(scope) do
    with :ok <- require_period_start(subscription.current_period_start_at),
         :ok <-
           validate_keep_grace_pair_interval(
             subscription.current_period_start_at,
             subscription.failed_payment_boundary_at
           ) do
      {:ok,
       %{
         disposition: :effective,
         entitlement_kind: kind,
         entitlement_scope_key: scope,
         valid_from_at: subscription.current_period_start_at,
         valid_until_at: subscription.failed_payment_boundary_at,
         source_order_line_item_id: subscription.source_order_line_item_id,
         contract_change_id: subscription.current_contract_change_id,
         plan_revision_id: subscription.current_plan_revision_id
       }}
    end
  end

  defp keep_during_grace_target_evidence(%Subscription{} = subscription, nil, nil) do
    {:ok,
     %{
       disposition: :effective,
       entitlement_kind: nil,
       entitlement_scope_key: nil,
       valid_from_at: nil,
       valid_until_at: subscription.failed_payment_boundary_at,
       source_order_line_item_id: subscription.source_order_line_item_id,
       contract_change_id: subscription.current_contract_change_id,
       plan_revision_id: subscription.current_plan_revision_id
     }}
  end

  defp keep_during_grace_target_evidence(%Subscription{}, _kind, _scope),
    do: incomplete_pair_error()

  defp validate_keep_grace_pair_interval(%DateTime{} = from, %DateTime{} = until) do
    if DateTime.compare(from, until) == :lt do
      :ok
    else
      {:error,
       Error.new(
         "TARGET_ORDER_UNPROVABLE",
         "keep_during_grace pair target requires valid_from_at before failed_payment_boundary_at"
       )}
    end
  end

  defp validate_keep_grace_pair_interval(_, _), do: missing_period_evidence_error()

  defp funded_entitlement_pair(%PlanRevision{} = revision) do
    {:ok, revision.entitlement_kind, revision.entitlement_scope_key}
  end

  defp require_failed_payment_boundary(%Subscription{failed_payment_boundary_at: %DateTime{}}),
    do: :ok

  defp require_failed_payment_boundary(%Subscription{}) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "failed payment boundary is required for keep_during_grace target derivation"
     )}
  end

  defp effective_target_evidence(%Subscription{} = subscription, kind, scope)
       when not is_nil(kind) and not is_nil(scope) do
    with :ok <- require_period_start(subscription.current_period_start_at) do
      {:ok,
       %{
         disposition: :effective,
         entitlement_kind: kind,
         entitlement_scope_key: scope,
         valid_from_at: subscription.current_period_start_at,
         valid_until_at: subscription.current_period_end_at,
         source_order_line_item_id: subscription.source_order_line_item_id,
         contract_change_id: subscription.current_contract_change_id,
         plan_revision_id: subscription.current_plan_revision_id
       }}
    end
  end

  defp effective_target_evidence(%Subscription{} = subscription, nil, nil) do
    {:ok,
     %{
       disposition: :effective,
       entitlement_kind: nil,
       entitlement_scope_key: nil,
       valid_from_at: nil,
       valid_until_at: subscription.current_period_end_at,
       source_order_line_item_id: subscription.source_order_line_item_id,
       contract_change_id: subscription.current_contract_change_id,
       plan_revision_id: subscription.current_plan_revision_id
     }}
  end

  defp effective_target_evidence(%Subscription{}, _kind, _scope), do: incomplete_pair_error()

  defp non_effective_evidence(%Subscription{} = subscription) do
    %{
      disposition: :non_effective,
      entitlement_kind: nil,
      entitlement_scope_key: nil,
      valid_from_at: nil,
      valid_until_at: nil,
      source_order_line_item_id: subscription.source_order_line_item_id,
      contract_change_id: subscription.current_contract_change_id,
      plan_revision_id: subscription.current_plan_revision_id
    }
  end

  defp revision_entitlement_pair(%PlanRevision{} = revision) do
    {:ok, revision.entitlement_kind, revision.entitlement_scope_key}
  end

  defp pair_present?(kind, scope) when not is_nil(kind) and not is_nil(scope), do: true
  defp pair_present?(nil, nil), do: false
  defp pair_present?(_, _), do: false

  defp datetimes_equal?(left, right) do
    case {left, right} do
      {nil, nil} -> true
      {%DateTime{} = a, %DateTime{} = b} -> DateTime.compare(a, b) == :eq
      _ -> false
    end
  end

  defp require_period_start(%DateTime{}), do: :ok
  defp require_period_start(_), do: missing_period_evidence_error()

  defp require_period_end(%DateTime{}), do: :ok
  defp require_period_end(_), do: missing_period_evidence_error()

  defp require_uuid(value, _label) when is_binary(value), do: :ok
  defp require_uuid(_value, _label), do: missing_provenance_error()

  defp unsupported_state(status) do
    {:error,
     Error.new(
       "TARGET_ORDER_UNSUPPORTED_STATE",
       "subscription status requires renewed authority review before target-order reconciliation",
       %{status: status}
     )}
  end

  defp missing_plan_revision_error do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "current PlanRevision evidence is required to derive the subscription target"
     )}
  end

  defp missing_period_evidence_error do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "current subscription period evidence is required to derive the effective target"
     )}
  end

  defp missing_provenance_error do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "immutable subscription provenance is required to derive the target"
     )}
  end

  defp incomplete_pair_error do
    {:error,
     Error.new(
       "TARGET_ORDER_UNPROVABLE",
       "PlanRevision entitlement pair must be complete or exactly nil"
     )}
  end
end
