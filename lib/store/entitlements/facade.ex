defmodule Store.Entitlements.Facade do
  @moduledoc """
  Entitlement read/write surfaces used by subscription orchestration.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Support.Errors.{Error, Normalize}

  @spec list_entitlements_for_user(map(), UserEntitlementIndexQuery.t()) ::
          {:ok, [EntitlementGrant.t()]} | {:error, term()}
  def list_entitlements_for_user(actor, %UserEntitlementIndexQuery{} = query)
      when is_map(actor) do
    ash_query =
      EntitlementGrant
      |> Ash.Query.for_read(:read_for_user, %{}, actor: actor)
      |> maybe_filter_status(query.status)
      |> Ash.Query.limit(query.limit)
      |> Ash.Query.offset(query.offset)

    case Ash.read(ash_query, domain: Entitlements, actor: actor) do
      {:ok, grants} -> {:ok, grants}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  def list_entitlements_for_user(_actor, _query) do
    {:error, Error.new("VALIDATION_ERROR", "actor and user entitlement query are required")}
  end

  @spec issue_subscription_entitlement_for_system(map(), map()) ::
          {:ok, EntitlementGrant.t()} | {:error, term()}
  def issue_subscription_entitlement_for_system(subscription, plan)
      when is_map(subscription) and is_map(plan) do
    entitlement_kind = Map.get(plan, :entitlement_kind)
    entitlement_scope_key = Map.get(plan, :entitlement_scope_key)

    if is_nil(entitlement_kind) or not is_binary(entitlement_scope_key) do
      {:error,
       Error.new("VALIDATION_ERROR", "subscription plan entitlement configuration is missing")}
    else
      valid_to_at = Map.get(subscription, :current_period_end_at)

      attrs = %{
        user_id: Map.get(subscription, :user_id),
        kind: entitlement_kind,
        scope_key: entitlement_scope_key,
        source_kind: :subscription,
        source_id: Map.get(subscription, :id),
        status: :active,
        valid_from_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        valid_to_at: valid_to_at,
        revoked_at: nil,
        revoked_reason: nil
      }

      EntitlementGrant
      |> Ash.Changeset.for_create(:issue, attrs, context: %{system?: true})
      |> Ash.create(domain: Entitlements, authorize?: false, context: %{system?: true})
    end
  end

  def issue_subscription_entitlement_for_system(_subscription, _plan) do
    {:error, Error.new("VALIDATION_ERROR", "subscription and plan are required")}
  end

  @spec revoke_subscription_entitlements_for_system(Ecto.UUID.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_subscription_entitlements_for_system(subscription_id, reason \\ nil)

  def revoke_subscription_entitlements_for_system(subscription_id, reason)
      when is_binary(subscription_id) do
    query =
      EntitlementGrant
      |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))

    case Ash.read(query, domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, grants} ->
        revoked_count =
          Enum.count(grants, fn grant ->
            revoke_grant(grant, reason)
          end)

        {:ok, revoked_count}

      {:error, reason} ->
        {:error, Normalize.normalize(reason)}
    end
  end

  def revoke_subscription_entitlements_for_system(_subscription_id, _reason) do
    {:error, Error.new("VALIDATION_ERROR", "subscription_id must be a UUID")}
  end

  defp revoke_grant(grant, reason) do
    attrs =
      if is_binary(reason) and reason != "" do
        %{revoked_reason: reason}
      else
        %{}
      end

    case grant
         |> Ash.Changeset.for_update(:revoke, attrs, context: %{system?: true})
         |> Ash.update(domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, _updated} -> true
      {:error, _reason} -> false
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: Ash.Query.filter(query, expr(status == ^status))
end
