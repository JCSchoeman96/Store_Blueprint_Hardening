defmodule Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput do
  @moduledoc """
  Immutable evidence for converging one Subscription source into Entitlements.
  """

  alias Store.Support.Errors.Error

  @dispositions [:effective, :non_effective]
  @entitlement_kinds [:membership_access, :digital_library, :discount_tier]
  @target_fingerprint_pattern ~r/\A[0-9a-f]{64}\z/

  @required_fields [
    :subscription_id,
    :user_id,
    :disposition,
    :entitlement_kind,
    :entitlement_scope_key,
    :valid_from_at,
    :valid_until_at,
    :reason,
    :access_effect_id,
    :source_version,
    :target_fingerprint
  ]

  @enforce_keys [
    :subscription_id,
    :user_id,
    :disposition,
    :entitlement_kind,
    :entitlement_scope_key,
    :valid_from_at,
    :valid_until_at,
    :reason,
    :access_effect_id,
    :source_version,
    :target_fingerprint
  ]
  defstruct [
    :subscription_id,
    :user_id,
    :disposition,
    :entitlement_kind,
    :entitlement_scope_key,
    :valid_from_at,
    :valid_until_at,
    :reason,
    :access_effect_id,
    :source_version,
    :target_fingerprint
  ]

  @type t :: %__MODULE__{
          subscription_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          disposition: :effective | :non_effective,
          entitlement_kind: :membership_access | :digital_library | :discount_tier | nil,
          entitlement_scope_key: String.t() | nil,
          valid_from_at: DateTime.t() | nil,
          valid_until_at: DateTime.t() | nil,
          reason: String.t(),
          access_effect_id: Ecto.UUID.t(),
          source_version: pos_integer(),
          target_fingerprint: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with :ok <- require_fields(params),
         {:ok, subscription_id} <- parse_uuid(params, :subscription_id),
         {:ok, user_id} <- parse_uuid(params, :user_id),
         {:ok, disposition} <- parse_enum(params, :disposition, @dispositions),
         {:ok, entitlement_kind} <-
           parse_optional_enum(params, :entitlement_kind, @entitlement_kinds),
         {:ok, entitlement_scope_key} <- parse_optional_scope(params),
         :ok <- validate_scope_pair(entitlement_kind, entitlement_scope_key),
         {:ok, valid_from_at} <- parse_optional_datetime(params, :valid_from_at),
         {:ok, valid_until_at} <- parse_optional_datetime(params, :valid_until_at),
         {:ok, reason} <- parse_reason(params),
         {:ok, access_effect_id} <- parse_uuid(params, :access_effect_id),
         {:ok, source_version} <- parse_positive_integer(params, :source_version),
         {:ok, target_fingerprint} <- parse_target_fingerprint(params),
         :ok <-
           validate_target(disposition, entitlement_kind, entitlement_scope_key, valid_from_at),
         :ok <-
           validate_interval(
             disposition,
             entitlement_kind,
             entitlement_scope_key,
             valid_from_at,
             valid_until_at
           ) do
      {:ok,
       %__MODULE__{
         subscription_id: subscription_id,
         user_id: user_id,
         disposition: disposition,
         entitlement_kind: entitlement_kind,
         entitlement_scope_key: entitlement_scope_key,
         valid_from_at: valid_from_at,
         valid_until_at: valid_until_at,
         reason: reason,
         access_effect_id: access_effect_id,
         source_version: source_version,
         target_fingerprint: target_fingerprint
       }}
    end
  end

  def new(_params),
    do:
      {:error,
       Error.new("VALIDATION_ERROR", "Subscription source convergence input must be a map")}

  defp require_fields(params) do
    case Enum.find(@required_fields, fn key -> not has_key?(params, key) end) do
      nil -> :ok
      key -> invalid(key, "is required")
    end
  end

  defp parse_uuid(params, key) do
    case value(params, key) do
      raw when is_binary(raw) ->
        case Ecto.UUID.cast(raw) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid(key, "must be a valid UUID")
        end

      _ ->
        invalid(key, "must be a valid UUID")
    end
  end

  defp parse_positive_integer(params, key) do
    case value(params, key) do
      integer when is_integer(integer) and integer > 0 ->
        {:ok, integer}

      string when is_binary(string) ->
        case Integer.parse(string) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _ -> invalid(key, "must be a positive integer")
        end

      _ ->
        invalid(key, "must be a positive integer")
    end
  end

  defp parse_enum(params, key, allowed) do
    case enum_value(value(params, key), allowed) do
      {:ok, enum} -> {:ok, enum}
      :error -> invalid(key, "is not supported")
    end
  end

  defp parse_optional_enum(params, key, allowed) do
    case value(params, key) do
      nil ->
        {:ok, nil}

      raw ->
        case enum_value(raw, allowed) do
          {:ok, enum} -> {:ok, enum}
          :error -> invalid(key, "is not supported")
        end
    end
  end

  defp enum_value(raw, allowed) when is_atom(raw) do
    if raw in allowed, do: {:ok, raw}, else: :error
  end

  defp enum_value(raw, allowed) when is_binary(raw) do
    Enum.find_value(allowed, :error, fn enum ->
      if Atom.to_string(enum) == raw, do: {:ok, enum}
    end)
  end

  defp enum_value(_raw, _allowed), do: :error

  defp parse_optional_scope(params) do
    case value(params, :entitlement_scope_key) do
      nil ->
        {:ok, nil}

      scope when is_binary(scope) and byte_size(scope) in 1..255 ->
        cond do
          not String.valid?(scope) ->
            invalid(:entitlement_scope_key, "must be valid UTF-8")

          String.trim(scope) == "" ->
            invalid(:entitlement_scope_key, "must not be blank")

          true ->
            {:ok, scope}
        end

      _ ->
        invalid(:entitlement_scope_key, "must be a string of 1 to 255 bytes or nil")
    end
  end

  defp validate_scope_pair(nil, nil), do: :ok

  defp validate_scope_pair(kind, scope) when not is_nil(kind) and is_binary(scope), do: :ok

  defp validate_scope_pair(nil, _scope),
    do: invalid(:entitlement_scope_key, "requires an entitlement kind")

  defp validate_scope_pair(_kind, nil),
    do: invalid(:entitlement_scope_key, "is required when an entitlement kind is supplied")

  defp parse_optional_datetime(params, key) do
    case value(params, key) do
      nil ->
        {:ok, nil}

      %DateTime{} = datetime ->
        {:ok, DateTime.truncate(datetime, :microsecond)}

      _ ->
        invalid(key, "must be a DateTime or nil")
    end
  end

  defp parse_reason(params) do
    case value(params, :reason) do
      reason when is_binary(reason) ->
        cond do
          not String.valid?(reason) -> invalid(:reason, "must be valid UTF-8")
          String.trim(reason) == "" -> invalid(:reason, "must not be blank")
          true -> {:ok, reason}
        end

      _ ->
        invalid(:reason, "must be a non-blank string")
    end
  end

  defp parse_target_fingerprint(params) do
    case value(params, :target_fingerprint) do
      fingerprint when is_binary(fingerprint) and byte_size(fingerprint) == 64 ->
        if String.valid?(fingerprint) and Regex.match?(@target_fingerprint_pattern, fingerprint) do
          {:ok, fingerprint}
        else
          invalid(
            :target_fingerprint,
            "must be a persisted 64-character lowercase hex fingerprint"
          )
        end

      _ ->
        invalid(:target_fingerprint, "must be a persisted 64-character lowercase hex fingerprint")
    end
  end

  defp validate_target(:effective, nil, nil, nil), do: :ok

  defp validate_target(:effective, kind, scope, nil)
       when not is_nil(kind) and is_binary(scope),
       do: invalid(:valid_from_at, "is required for an EFFECTIVE entitlement pair")

  defp validate_target(:effective, kind, scope, %DateTime{})
       when not is_nil(kind) and is_binary(scope),
       do: :ok

  defp validate_target(:effective, nil, nil, %DateTime{}),
    do: invalid(:valid_from_at, "must be nil for an empty target")

  defp validate_target(:non_effective, nil, nil, nil), do: :ok

  defp validate_target(:non_effective, _kind, _scope, _valid_from_at),
    do: invalid(:disposition, "requires an empty target for NON_EFFECTIVE input")

  defp validate_interval(:effective, kind, scope, %DateTime{} = start_at, %DateTime{} = end_at)
       when not is_nil(kind) and is_binary(scope) do
    case DateTime.compare(start_at, end_at) do
      :lt -> :ok
      :eq -> invalid(:valid_until_at, "must be later than valid_from_at")
      :gt -> invalid(:valid_until_at, "must be later than valid_from_at")
    end
  end

  defp validate_interval(_disposition, _kind, _scope, _start_at, _end_at), do: :ok

  defp has_key?(params, key),
    do: Map.has_key?(params, key) or Map.has_key?(params, Atom.to_string(key))

  defp value(params, key) do
    if Map.has_key?(params, key),
      do: Map.get(params, key),
      else: Map.get(params, Atom.to_string(key))
  end

  defp invalid(key, message) do
    {:error, Error.new("VALIDATION_ERROR", "#{key} #{message}")}
  end
end
