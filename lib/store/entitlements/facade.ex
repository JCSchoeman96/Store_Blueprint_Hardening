defmodule Store.Entitlements.Facade do
  @moduledoc """
  Entitlement read/write surfaces used by subscription orchestration.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Entitlements
  alias Store.Entitlements.Cache, as: EntitlementsCache
  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Queries.UserEntitlementIndexQuery
  alias Store.Entitlements.Types.EntitlementSet
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

  @spec entitlement_set_for_user(map()) :: {:ok, EntitlementSet.t()} | {:error, term()}
  def entitlement_set_for_user(%{id: user_id} = actor) when is_binary(user_id) do
    EntitlementsCache.fetch(user_id, fn ->
      case fetch_active_grants_for_user(actor) do
        {:ok, grants} -> {:commit, build_entitlement_set(user_id, grants)}
        {:error, reason} -> {:ignore, reason}
      end
    end)
    |> normalize_entitlement_set_result()
  end

  def entitlement_set_for_user(_actor) do
    {:error, Error.new("VALIDATION_ERROR", "actor with id is required")}
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
      |> case do
        {:ok, grant} ->
          maybe_invalidate_user(subscription.user_id, "entitlement_issued")
          {:ok, grant}

        {:error, reason} ->
          {:error, reason}
      end
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

        if revoked_count > 0 do
          user_ids =
            grants
            |> Enum.map(& &1.user_id)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          Enum.each(user_ids, &maybe_invalidate_user(&1, reason || "entitlement_revoked"))
        end

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

  defp fetch_active_grants_for_user(%{id: user_id}) do
    query =
      EntitlementGrant
      |> Ash.Query.filter(expr(user_id == ^user_id and status == :active))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)

    case Ash.read(query, domain: Entitlements, authorize?: false, context: %{system?: true}) do
      {:ok, grants} -> {:ok, grants}
      {:error, reason} -> {:error, Normalize.normalize(reason)}
    end
  end

  defp build_entitlement_set(user_id, grants) do
    fetched_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %EntitlementSet{
      user_id: user_id,
      grants: grants,
      scopes_by_kind: scopes_by_kind(grants, fetched_at),
      fetched_at: fetched_at,
      expires_at: DateTime.add(fetched_at, div(EntitlementsCache.ttl_ms(), 1_000), :second)
    }
  end

  defp scopes_by_kind(grants, now) do
    %EntitlementSet{
      user_id: "__build__",
      grants: grants,
      scopes_by_kind: %{},
      fetched_at: now,
      expires_at: now
    }
    |> EntitlementSet.effective_grants(now)
    |> Enum.reduce(%{}, fn grant, acc ->
      Map.update(acc, grant.kind, MapSet.new([grant.scope_key]), &MapSet.put(&1, grant.scope_key))
    end)
  end

  defp normalize_entitlement_set_result({:ok, %EntitlementSet{} = set}), do: {:ok, set}
  defp normalize_entitlement_set_result({:ok, reason}), do: {:error, Normalize.normalize(reason)}

  defp normalize_entitlement_set_result({:error, reason}),
    do: {:error, Normalize.normalize(reason)}

  defp maybe_invalidate_user(user_id, reason) when is_binary(user_id) do
    EntitlementsCache.invalidate_and_broadcast_post_commit(user_id, reason)
  end

  defp maybe_invalidate_user(_user_id, _reason), do: :ok
end
