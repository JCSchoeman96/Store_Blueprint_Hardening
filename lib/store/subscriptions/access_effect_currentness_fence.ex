defmodule Store.Subscriptions.AccessEffectCurrentnessFence do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Subscription}
  alias Store.Support.Errors.Error

  @type status :: :current | :stale
  @type evidence :: %{
          status: status(),
          source: %{subscription_id: Ecto.UUID.t(), user_id: Ecto.UUID.t()},
          access_effect: AccessEffect.t(),
          latest_access_effect_id: Ecto.UUID.t()
        }

  @spec prove(Ecto.UUID.t()) :: {:ok, evidence()} | {:error, Error.t()}
  def prove(access_effect_id) do
    if Repo.in_transaction?() do
      prove_in_transaction(access_effect_id)
    else
      validation_error("AccessEffect currentness requires a caller transaction")
    end
  end

  defp prove_in_transaction(access_effect_id) do
    with {:ok, exact_id} <- cast_access_effect_id(access_effect_id),
         {:ok, subscription_id} <- find_candidate_subscription_id(exact_id),
         {:ok, source} <- lock_subscription(subscription_id),
         {:ok, candidate} <- lock_candidate(exact_id),
         :ok <- validate_source_identity(candidate, source),
         :ok <- validate_source_version(candidate, source),
         :ok <- validate_fingerprint(candidate),
         :ok <- validate_executable_target(candidate),
         {:ok, latest} <- find_latest_effect(source.id) do
      {:ok,
       %{
         status: if(latest.id == candidate.id, do: :current, else: :stale),
         source: %{subscription_id: source.id, user_id: source.user_id},
         access_effect: candidate,
         latest_access_effect_id: latest.id
       }}
    end
  end

  defp cast_access_effect_id(access_effect_id) when is_binary(access_effect_id) do
    case Ecto.UUID.cast(access_effect_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> validation_error("AccessEffect id must be a UUID")
    end
  end

  defp cast_access_effect_id(_access_effect_id),
    do: validation_error("AccessEffect id must be a UUID")

  defp find_candidate_subscription_id(access_effect_id) do
    query =
      from effect in AccessEffect,
        where: effect.id == ^access_effect_id,
        select: effect.subscription_id

    case Repo.one(query) do
      nil -> not_found("AccessEffect was not found")
      subscription_id -> {:ok, subscription_id}
    end
  end

  defp lock_subscription(subscription_id) do
    query =
      from source in Subscription,
        where: source.id == ^subscription_id,
        lock: "FOR UPDATE",
        select: %{
          id: source.id,
          user_id: source.user_id,
          aggregate_version: source.aggregate_version
        }

    case Repo.one(query) do
      nil -> not_found("Subscription was not found")
      source -> {:ok, source}
    end
  end

  defp lock_candidate(access_effect_id) do
    query =
      from effect in AccessEffect,
        where: effect.id == ^access_effect_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> not_found("AccessEffect was not found")
      candidate -> {:ok, candidate}
    end
  end

  defp validate_source_identity(candidate, source) do
    if candidate.subscription_id == source.id do
      :ok
    else
      internal_error("AccessEffect subscription identity changed during currentness proof")
    end
  end

  defp validate_source_version(candidate, source) do
    if candidate.source_version <= source.aggregate_version do
      :ok
    else
      internal_error("AccessEffect source version exceeds the locked aggregate version")
    end
  end

  defp validate_fingerprint(candidate) do
    case AccessEffect.persisted_fingerprint_status(candidate) do
      :v2_match ->
        :ok

      :v1_legacy_match ->
        :ok

      :mismatch ->
        internal_error("AccessEffect target fingerprint does not match persisted evidence")
    end
  end

  defp validate_executable_target(%AccessEffect{
         disposition: :effective,
         entitlement_kind: kind,
         entitlement_scope_key: scope,
         valid_from_at: %DateTime{} = valid_from_at,
         valid_until_at: valid_until_at
       })
       when not is_nil(kind) and not is_nil(scope) do
    if valid_entitlement_scope_key?(scope) do
      validate_pair_interval(valid_from_at, valid_until_at)
    else
      validation_error("AccessEffect entitlement scope key is invalid")
    end
  end

  defp validate_executable_target(%AccessEffect{
         disposition: disposition,
         entitlement_kind: nil,
         entitlement_scope_key: nil,
         valid_from_at: nil
       })
       when disposition in [:effective, :non_effective],
       do: :ok

  defp validate_executable_target(_candidate),
    do: validation_error("AccessEffect target is not executable")

  defp validate_pair_interval(_valid_from_at, nil), do: :ok

  defp validate_pair_interval(%DateTime{} = valid_from_at, %DateTime{} = valid_until_at) do
    if DateTime.compare(valid_from_at, valid_until_at) == :lt do
      :ok
    else
      validation_error("AccessEffect valid_from_at must be before valid_until_at")
    end
  end

  defp validate_pair_interval(_valid_from_at, _valid_until_at),
    do: validation_error("AccessEffect interval must contain DateTime evidence")

  defp valid_entitlement_scope_key?(scope) when is_binary(scope) do
    byte_size(scope) in 1..255 and String.valid?(scope) and String.trim(scope) != ""
  end

  defp valid_entitlement_scope_key?(_scope), do: false

  defp find_latest_effect(subscription_id) do
    query =
      from effect in AccessEffect,
        where: effect.subscription_id == ^subscription_id,
        order_by: [desc: effect.source_version],
        limit: 1,
        select: %{id: effect.id, source_version: effect.source_version}

    case Repo.one(query) do
      nil -> internal_error("AccessEffect latest-source row is missing")
      latest -> {:ok, latest}
    end
  end

  defp not_found(message), do: {:error, Error.new("NOT_FOUND", message)}
  defp validation_error(message), do: {:error, Error.new("VALIDATION_ERROR", message)}
  defp internal_error(message), do: {:error, Error.new("INTERNAL_ERROR", message)}
end
