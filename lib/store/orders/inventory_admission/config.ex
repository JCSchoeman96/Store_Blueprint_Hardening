defmodule Store.Orders.InventoryAdmission.Config do
  @moduledoc """
  Typed, server-owned configuration for InventoryAdmission.

  This module validates the rollout contract without starting processes or
  connecting to PostgreSQL or Redis. Admission wiring will consume the
  validated struct in a later IA-04 slice.
  """

  @enforced_modes [:disabled, :enforced]
  @scope_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/
  @version_regex ~r/\Av[0-9]+\z/

  @redis_option_keys [
    :hmac_key,
    :scope,
    :b_total,
    :q_variant_max,
    :q_global_max,
    :queue_window_ms,
    :db_window_ms,
    :lease_window_ms,
    :safety_margin_ms,
    :cleanup_limit,
    :metadata_retention_ms
  ]

  @config_keys [
    :mode,
    :scope,
    :repo_pool_capacity,
    :repo_headroom,
    :b_total,
    :q_variant_max,
    :q_global_max,
    :queue_window_ms,
    :db_window_ms,
    :lease_window_ms,
    :safety_margin_ms,
    :cleanup_limit,
    :metadata_retention_ms,
    :hmac_key,
    :hmac_key_version,
    :database_safety_window_ms,
    :recovery_retry_budget,
    :recovery_deadline_ms,
    :redis_restart_quarantine_ms
  ]

  @default_values [
    mode: :disabled,
    scope: "default",
    repo_pool_capacity: nil,
    repo_headroom: nil,
    b_total: nil,
    q_variant_max: 10,
    q_global_max: 100,
    queue_window_ms: 10_000,
    db_window_ms: 2_000,
    lease_window_ms: 3_000,
    safety_margin_ms: 500,
    cleanup_limit: 100,
    metadata_retention_ms: 86_400_000,
    hmac_key: nil,
    hmac_key_version: "v1",
    database_safety_window_ms: 1_000,
    recovery_retry_budget: 3,
    recovery_deadline_ms: 5_000,
    redis_restart_quarantine_ms: 2_000
  ]

  @enforced_capacity_fields [:repo_pool_capacity, :repo_headroom, :b_total]
  @positive_fields [
    :q_variant_max,
    :q_global_max,
    :queue_window_ms,
    :db_window_ms,
    :lease_window_ms,
    :cleanup_limit,
    :metadata_retention_ms,
    :database_safety_window_ms,
    :recovery_retry_budget,
    :recovery_deadline_ms,
    :redis_restart_quarantine_ms
  ]

  @type mode :: :disabled | :enforced

  @type t :: %__MODULE__{
          mode: mode(),
          scope: String.t(),
          repo_pool_capacity: pos_integer() | nil,
          repo_headroom: pos_integer() | nil,
          b_total: pos_integer() | nil,
          q_variant_max: pos_integer(),
          q_global_max: pos_integer(),
          queue_window_ms: pos_integer(),
          db_window_ms: pos_integer(),
          lease_window_ms: pos_integer(),
          safety_margin_ms: non_neg_integer(),
          cleanup_limit: pos_integer(),
          metadata_retention_ms: pos_integer(),
          hmac_key: binary() | nil,
          hmac_key_version: String.t(),
          database_safety_window_ms: pos_integer(),
          recovery_retry_budget: pos_integer(),
          recovery_deadline_ms: pos_integer(),
          redis_restart_quarantine_ms: pos_integer()
        }

  defstruct @default_values

  @doc "Loads and validates the server-owned InventoryAdmission settings."
  @spec load() :: {:ok, t()} | {:error, {:invalid_configuration, atom()}}
  def load do
    :store
    |> Application.get_env(:inventory_admission, [])
    |> from_keyword()
  end

  @doc "Validates a typed InventoryAdmission configuration."
  @spec validate(t()) :: :ok | {:error, {:invalid_configuration, atom()}}
  def validate(%__MODULE__{} = config) do
    with :ok <- validate_mode(config.mode),
         :ok <- validate_scope(config.scope),
         :ok <- validate_hmac_key_version(config.hmac_key_version),
         :ok <- validate_structural_values(config),
         :ok <- validate_hmac_key(config) do
      validate_enforced_capacity(config)
    end
  end

  def validate(_config), do: invalid(:configuration)

  @doc "Returns whether the validated configuration enables enforcement."
  @spec enforced?(t()) :: boolean()
  def enforced?(%__MODULE__{mode: :enforced}), do: true
  def enforced?(%__MODULE__{}), do: false

  @doc "Returns the IA-03-compatible Redis keyword options only."
  @spec redis_options(t()) :: keyword()
  def redis_options(%__MODULE__{} = config) do
    Enum.map(@redis_option_keys, &{&1, Map.fetch!(config, &1)})
  end

  defp from_keyword(values) when is_list(values) do
    if Keyword.keyword?(values) and Enum.all?(Keyword.keys(values), &(&1 in @config_keys)) do
      config = struct(__MODULE__, Keyword.merge(@default_values, values))

      case validate(config) do
        :ok -> {:ok, config}
        {:error, _reason} = error -> error
      end
    else
      invalid(:configuration)
    end
  end

  defp from_keyword(_values), do: invalid(:configuration)

  defp validate_mode(mode) when mode in @enforced_modes, do: :ok
  defp validate_mode(_mode), do: invalid(:mode)

  defp validate_scope(scope) when is_binary(scope) do
    if Regex.match?(@scope_regex, scope), do: :ok, else: invalid(:scope)
  end

  defp validate_scope(_scope), do: invalid(:scope)

  defp validate_hmac_key_version(version) when is_binary(version) do
    if Regex.match?(@version_regex, version), do: :ok, else: invalid(:hmac_key_version)
  end

  defp validate_hmac_key_version(_version), do: invalid(:hmac_key_version)

  defp validate_structural_values(config) do
    with :ok <- validate_positive_fields(config),
         :ok <- validate_non_negative(config.safety_margin_ms) do
      with :ok <- validate_lease_window(config) do
        validate_recovery_deadline(config)
      end
    end
  end

  defp validate_positive_fields(config) do
    Enum.find_value(@positive_fields, :ok, fn field ->
      case Map.fetch!(config, field) do
        value when is_integer(value) and value > 0 -> nil
        _value -> invalid(field)
      end
    end)
  end

  defp validate_non_negative(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(_value), do: invalid(:safety_margin_ms)

  defp validate_lease_window(%__MODULE__{
         lease_window_ms: lease_window_ms,
         db_window_ms: db_window_ms,
         safety_margin_ms: safety_margin_ms
       }) do
    if lease_window_ms >= db_window_ms + safety_margin_ms do
      :ok
    else
      invalid(:lease_window_ms)
    end
  end

  defp validate_recovery_deadline(%__MODULE__{
         database_safety_window_ms: safety_window_ms,
         recovery_deadline_ms: recovery_deadline_ms
       }) do
    if recovery_deadline_ms > safety_window_ms do
      :ok
    else
      invalid(:recovery_deadline_ms)
    end
  end

  defp validate_hmac_key(%__MODULE__{mode: :disabled}), do: :ok

  defp validate_hmac_key(%__MODULE__{mode: :enforced, hmac_key: key})
       when is_binary(key) and byte_size(key) > 0,
       do: :ok

  defp validate_hmac_key(%__MODULE__{mode: :enforced}), do: invalid(:hmac_key)

  defp validate_enforced_capacity(%__MODULE__{mode: :disabled}), do: :ok

  defp validate_enforced_capacity(%__MODULE__{} = config) do
    with :ok <- validate_capacity_fields(config) do
      validate_budget(config)
    end
  end

  defp validate_capacity_fields(config) do
    Enum.find_value(@enforced_capacity_fields, :ok, fn field ->
      case Map.fetch!(config, field) do
        value when is_integer(value) and value > 0 -> nil
        _value -> invalid(field)
      end
    end)
  end

  defp validate_budget(%__MODULE__{
         repo_pool_capacity: repo_pool_capacity,
         repo_headroom: repo_headroom,
         b_total: b_total
       }) do
    cond do
      repo_headroom >= repo_pool_capacity -> invalid(:repo_headroom)
      b_total > repo_pool_capacity - repo_headroom -> invalid(:b_total)
      true -> :ok
    end
  end

  defp invalid(field), do: {:error, {:invalid_configuration, field}}
end
