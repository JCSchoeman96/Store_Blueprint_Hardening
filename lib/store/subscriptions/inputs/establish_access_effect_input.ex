defmodule Store.Subscriptions.Inputs.EstablishAccessEffectInput do
  @moduledoc """
  Canonical Subscription target evidence used to establish or reuse an AccessEffect.
  """

  alias Store.Support.Errors.Error

  @dispositions [:effective, :non_effective]
  @entitlement_kinds [:membership_access, :digital_library, :discount_tier]

  @enforce_keys [
    :subscription_id,
    :source_version,
    :disposition,
    :entitlement_kind,
    :entitlement_scope_key,
    :valid_until_at,
    :source_order_line_item_id,
    :plan_revision_id
  ]
  defstruct [
    :subscription_id,
    :source_version,
    :disposition,
    :entitlement_kind,
    :entitlement_scope_key,
    :valid_until_at,
    :source_order_line_item_id,
    :contract_change_id,
    :plan_revision_id
  ]

  @type t :: %__MODULE__{
          subscription_id: Ecto.UUID.t(),
          source_version: pos_integer(),
          disposition: :effective | :non_effective,
          entitlement_kind: atom() | nil,
          entitlement_scope_key: String.t() | nil,
          valid_until_at: DateTime.t() | nil,
          source_order_line_item_id: Ecto.UUID.t(),
          contract_change_id: Ecto.UUID.t() | nil,
          plan_revision_id: Ecto.UUID.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) when is_map(params) do
    with {:ok, subscription_id} <- parse_uuid(params, :subscription_id),
         {:ok, source_version} <- parse_positive_integer(params, :source_version),
         {:ok, disposition} <- parse_enum(params, :disposition, @dispositions),
         {:ok, entitlement_kind} <-
           parse_optional_enum(params, :entitlement_kind, @entitlement_kinds),
         {:ok, entitlement_scope_key} <- parse_optional_scope(params),
         :ok <- validate_scope_pair(entitlement_kind, entitlement_scope_key),
         {:ok, valid_until_at} <- parse_optional_datetime(params, :valid_until_at),
         {:ok, source_order_line_item_id} <- parse_uuid(params, :source_order_line_item_id),
         {:ok, contract_change_id} <- parse_optional_uuid(params, :contract_change_id),
         {:ok, plan_revision_id} <- parse_uuid(params, :plan_revision_id) do
      {:ok,
       %__MODULE__{
         subscription_id: subscription_id,
         source_version: source_version,
         disposition: disposition,
         entitlement_kind: entitlement_kind,
         entitlement_scope_key: entitlement_scope_key,
         valid_until_at: valid_until_at,
         source_order_line_item_id: source_order_line_item_id,
         contract_change_id: contract_change_id,
         plan_revision_id: plan_revision_id
       }}
    end
  end

  def new(_params),
    do: {:error, Error.new("VALIDATION_ERROR", "AccessEffect input must be a map")}

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

  defp parse_optional_uuid(params, key) do
    case value(params, key) do
      nil ->
        {:ok, nil}

      raw when is_binary(raw) ->
        case Ecto.UUID.cast(raw) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid(key, "must be a valid UUID or nil")
        end

      _ ->
        invalid(key, "must be a valid UUID or nil")
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

  defp validate_scope_pair(nil, _scope),
    do: invalid(:entitlement_scope_key, "requires an entitlement kind")

  defp validate_scope_pair(_kind, _scope), do: :ok

  defp parse_optional_datetime(params, key) do
    case value(params, key) do
      nil -> {:ok, nil}
      %DateTime{} = datetime -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _ -> invalid(key, "must be a DateTime or nil")
    end
  end

  defp value(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp invalid(key, message) do
    {:error, Error.new("VALIDATION_ERROR", "#{key} #{message}")}
  end
end
