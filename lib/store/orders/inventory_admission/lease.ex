defmodule Store.Orders.InventoryAdmission.Lease do
  @moduledoc """
  Ephemeral admission ownership value.

  A lease identifies coordination ownership for one variant and its bounded deadlines.
  It does not represent stock ownership, a durable reservation, or a proof of commit.
  """

  alias Store.Support.ID.UUIDv7

  @allowed_keys MapSet.new([
                  :admission_member,
                  :admission_ref,
                  :variant_id,
                  :lease_token,
                  :owner_epoch,
                  :identity_digest,
                  :db_deadline,
                  :lease_deadline,
                  :safety_margin
                ])

  @enforce_keys [
    :admission_member,
    :variant_id,
    :lease_token,
    :owner_epoch,
    :identity_digest,
    :db_deadline,
    :lease_deadline,
    :safety_margin
  ]
  defstruct [
    :admission_member,
    :variant_id,
    :lease_token,
    :owner_epoch,
    :identity_digest,
    :db_deadline,
    :lease_deadline,
    :safety_margin
  ]

  @type t :: %__MODULE__{
          admission_member: String.t(),
          variant_id: Ecto.UUID.t(),
          lease_token: String.t(),
          owner_epoch: pos_integer(),
          identity_digest: String.t(),
          db_deadline: non_neg_integer(),
          lease_deadline: non_neg_integer(),
          safety_margin: non_neg_integer()
        }

  @spec new(map() | t()) :: {:ok, t()} | {:error, atom()}
  def new(%__MODULE__{} = lease) do
    case validate(lease) do
      :ok -> {:ok, lease}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(params) when is_map(params) do
    with :ok <- validate_keys(params),
         {:ok, admission_member} <- fetch_admission_member(params),
         {:ok, variant_id} <- fetch_variant_id(params),
         {:ok, lease_token} <- fetch_non_empty_binary(params, :lease_token),
         {:ok, owner_epoch} <- fetch_positive_integer(params, :owner_epoch),
         {:ok, identity_digest} <- fetch_non_empty_binary(params, :identity_digest),
         {:ok, db_deadline} <- fetch_non_negative_integer(params, :db_deadline),
         {:ok, lease_deadline} <- fetch_non_negative_integer(params, :lease_deadline),
         {:ok, safety_margin} <- fetch_non_negative_integer(params, :safety_margin),
         :ok <- validate_deadline_relationship(db_deadline, lease_deadline, safety_margin) do
      {:ok,
       %__MODULE__{
         admission_member: admission_member,
         variant_id: variant_id,
         lease_token: lease_token,
         owner_epoch: owner_epoch,
         identity_digest: identity_digest,
         db_deadline: db_deadline,
         lease_deadline: lease_deadline,
         safety_margin: safety_margin
       }}
    end
  end

  def new(_params), do: {:error, :invalid_lease}

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = lease) do
    with :ok <- validate_non_empty_binary(lease.admission_member, :admission_member),
         {:ok, normalized_variant_id} <- normalize_variant_id(lease.variant_id),
         :ok <- validate_non_empty_binary(lease.lease_token, :lease_token),
         :ok <- validate_positive_integer(lease.owner_epoch, :owner_epoch),
         :ok <- validate_non_empty_binary(lease.identity_digest, :identity_digest),
         :ok <- validate_non_negative_integer(lease.db_deadline, :db_deadline),
         :ok <- validate_non_negative_integer(lease.lease_deadline, :lease_deadline),
         :ok <- validate_non_negative_integer(lease.safety_margin, :safety_margin),
         :ok <-
           validate_deadline_relationship(
             lease.db_deadline,
             lease.lease_deadline,
             lease.safety_margin
           ) do
      validate_normalized_variant_id(lease.variant_id, normalized_variant_id)
    end
  end

  def validate(_lease), do: {:error, :invalid_lease}

  @spec valid?(term()) :: boolean()
  def valid?(lease), do: match?(:ok, validate(lease))

  @spec remaining_db_budget(t(), non_neg_integer()) :: non_neg_integer()
  def remaining_db_budget(%__MODULE__{db_deadline: db_deadline}, monotonic_now)
      when is_integer(monotonic_now) and monotonic_now >= 0 do
    max(db_deadline - monotonic_now, 0)
  end

  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{} = lease, monotonic_now)
      when is_integer(monotonic_now) and monotonic_now >= 0 do
    remaining_db_budget(lease, monotonic_now) == 0
  end

  defp validate_keys(params) do
    cond do
      Map.has_key?(params, :admission_member) and Map.has_key?(params, :admission_ref) ->
        {:error, :multiple_admission_identities}

      Enum.all?(Map.keys(params), &MapSet.member?(@allowed_keys, &1)) ->
        :ok

      true ->
        {:error, :unknown_lease_key}
    end
  end

  defp fetch_admission_member(params) do
    cond do
      Map.has_key?(params, :admission_member) ->
        fetch_non_empty_binary(params, :admission_member)

      Map.has_key?(params, :admission_ref) ->
        fetch_non_empty_binary(params, :admission_ref)

      true ->
        {:error, :admission_member_required}
    end
  end

  defp fetch_variant_id(params) do
    case Map.fetch(params, :variant_id) do
      {:ok, value} -> normalize_variant_id(value)
      :error -> {:error, :lease_variant_id_required}
    end
  end

  defp normalize_variant_id(value) do
    case UUIDv7.decode(value) do
      {:ok, raw16} -> {:ok, UUIDv7.encode!(raw16)}
      :error -> {:error, :invalid_lease_variant_id}
    end
  end

  defp validate_normalized_variant_id(variant_id, normalized_variant_id)
       when variant_id == normalized_variant_id,
       do: :ok

  defp validate_normalized_variant_id(_variant_id, _normalized_variant_id),
    do: {:error, :lease_variant_id_not_normalized}

  defp fetch_non_empty_binary(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        case validate_non_empty_binary(value, key) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, required_reason(key)}
    end
  end

  defp validate_non_empty_binary(value, _key) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp validate_non_empty_binary(_value, :admission_member),
    do: {:error, :admission_member_must_be_non_empty}

  defp validate_non_empty_binary(_value, :lease_token),
    do: {:error, :lease_token_must_be_non_empty}

  defp validate_non_empty_binary(_value, :identity_digest),
    do: {:error, :identity_digest_must_be_non_empty}

  defp fetch_positive_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_integer_reason(key)}
      :error -> {:error, required_reason(key)}
    end
  end

  defp fetch_non_negative_integer(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_integer_reason(key)}
      :error -> {:error, required_reason(key)}
    end
  end

  defp validate_positive_integer(value, _key) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(_value, :owner_epoch),
    do: {:error, :owner_epoch_must_be_positive}

  defp validate_non_negative_integer(value, _key)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_non_negative_integer(_value, :db_deadline), do: {:error, :invalid_db_deadline}

  defp validate_non_negative_integer(_value, :lease_deadline),
    do: {:error, :invalid_lease_deadline}

  defp validate_non_negative_integer(_value, :safety_margin), do: {:error, :invalid_safety_margin}

  defp validate_deadline_relationship(db_deadline, lease_deadline, safety_margin) do
    if lease_deadline >= db_deadline + safety_margin do
      :ok
    else
      {:error, :lease_deadline_before_db_deadline_plus_safety_margin}
    end
  end

  defp required_reason(:admission_member), do: :admission_member_required
  defp required_reason(:admission_ref), do: :admission_ref_required
  defp required_reason(:variant_id), do: :lease_variant_id_required
  defp required_reason(:lease_token), do: :lease_token_required
  defp required_reason(:owner_epoch), do: :owner_epoch_required
  defp required_reason(:identity_digest), do: :identity_digest_required
  defp required_reason(:db_deadline), do: :db_deadline_required
  defp required_reason(:lease_deadline), do: :lease_deadline_required
  defp required_reason(:safety_margin), do: :safety_margin_required

  defp invalid_integer_reason(:owner_epoch), do: :owner_epoch_must_be_positive
  defp invalid_integer_reason(:db_deadline), do: :invalid_db_deadline
  defp invalid_integer_reason(:lease_deadline), do: :invalid_lease_deadline
  defp invalid_integer_reason(:safety_margin), do: :invalid_safety_margin
end
