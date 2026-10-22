defmodule Store.Entitlements.SourceConvergence do
  @moduledoc false

  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort
  alias Store.Support.ID.UUIDv7

  @entitlement_kinds [:membership_access, :digital_library, :discount_tier]
  @statuses [:active, :revoked, :expired]

  @type locked_source_state :: %{
          mode: :pair | :empty,
          matching_target_id: Ecto.UUID.t() | nil,
          active_non_target_ids: [Ecto.UUID.t()],
          expected_revoke_count: non_neg_integer(),
          projection_user_ids: [Ecto.UUID.t()]
        }

  @spec derive_locked_source_state(SubscriptionSourceConvergenceInput.t(), [map()]) ::
          {:ok, locked_source_state()} | {:error, Error.t()}
  def derive_locked_source_state(input, locked_rows) do
    with {:ok, mode} <- target_mode(input),
         true <- valid_input_identity?(input),
         {:ok, rows} <- normalize_rows(locked_rows, input.subscription_id),
         :ok <- unique_row_ids(rows),
         {:ok, matching_target_id} <- matching_target_id(mode, input, rows),
         {:ok, active_non_target_ids} <-
           active_non_target_ids(mode, input, matching_target_id, rows),
         {:ok, projection_user_ids} <-
           sorted_unique_uuids([input.user_id | Enum.map(rows, & &1.user_id)]) do
      {:ok,
       %{
         mode: mode,
         matching_target_id: matching_target_id,
         active_non_target_ids: active_non_target_ids,
         expected_revoke_count: length(active_non_target_ids),
         projection_user_ids: projection_user_ids
       }}
    else
      _ -> internal_error()
    end
  end

  @spec validate_final_active_set(
          SubscriptionSourceConvergenceInput.t(),
          Ecto.UUID.t() | nil,
          [map()]
        ) :: :ok | {:error, Error.t()}
  def validate_final_active_set(input, target_grant_id, selected_active_rows) do
    with {:ok, mode} <- target_mode(input),
         true <- valid_input_identity?(input),
         true <- is_list(selected_active_rows),
         true <- final_active_set_matches?(mode, input, target_grant_id, selected_active_rows) do
      :ok
    else
      _ -> internal_error()
    end
  end

  defp target_mode(%SubscriptionSourceConvergenceInput{
         disposition: :effective,
         entitlement_kind: kind,
         entitlement_scope_key: scope_key,
         valid_from_at: %DateTime{} = valid_from_at,
         valid_until_at: valid_until_at
       })
       when kind in @entitlement_kinds and is_binary(scope_key) and
              (is_nil(valid_until_at) or is_struct(valid_until_at, DateTime)) do
    if valid_target_scope?(scope_key) and valid_pair_interval?(valid_from_at, valid_until_at) do
      {:ok, :pair}
    else
      :error
    end
  end

  defp target_mode(%SubscriptionSourceConvergenceInput{
         disposition: :effective,
         entitlement_kind: nil,
         entitlement_scope_key: nil,
         valid_from_at: nil,
         valid_until_at: valid_until_at
       })
       when is_nil(valid_until_at) or is_struct(valid_until_at, DateTime),
       do: {:ok, :empty}

  defp target_mode(%SubscriptionSourceConvergenceInput{
         disposition: :non_effective,
         entitlement_kind: nil,
         entitlement_scope_key: nil,
         valid_from_at: nil,
         valid_until_at: valid_until_at
       })
       when is_nil(valid_until_at) or is_struct(valid_until_at, DateTime),
       do: {:ok, :empty}

  defp target_mode(_input), do: :error

  defp valid_pair_interval?(_valid_from_at, nil), do: true

  defp valid_pair_interval?(%DateTime{} = valid_from_at, %DateTime{} = valid_until_at) do
    DateTime.compare(valid_from_at, valid_until_at) == :lt
  end

  defp valid_target_scope?(scope_key) do
    byte_size(scope_key) in 1..255 and String.valid?(scope_key) and
      String.trim(scope_key) != ""
  end

  defp valid_input_identity?(%SubscriptionSourceConvergenceInput{
         subscription_id: subscription_id,
         user_id: user_id
       }) do
    valid_uuid_string?(subscription_id) and valid_uuid_string?(user_id)
  end

  defp valid_input_identity?(_input), do: false

  defp normalize_rows(rows, subscription_id) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, normalized_rows} ->
      case normalize_source_row(row, subscription_id) do
        {:ok, normalized_row} ->
          {:cont, {:ok, [normalized_row | normalized_rows]}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized_rows} -> {:ok, Enum.reverse(normalized_rows)}
      :error -> :error
    end
  end

  defp normalize_rows(_rows, _subscription_id), do: :error

  defp normalize_source_row(row, subscription_id) when is_map(row) do
    with {:ok, id} <- fetch_field(row, :id),
         {:ok, user_id} <- fetch_field(row, :user_id),
         {:ok, kind} <- fetch_field(row, :kind),
         {:ok, scope_key} <- fetch_field(row, :scope_key),
         {:ok, source_kind} <- fetch_field(row, :source_kind),
         {:ok, source_id} <- fetch_field(row, :source_id),
         {:ok, status} <- fetch_field(row, :status),
         {:ok, valid_from_at} <- fetch_field(row, :valid_from_at),
         {:ok, valid_to_at} <- fetch_field(row, :valid_to_at),
         {:ok, revoked_at} <- fetch_field(row, :revoked_at),
         {:ok, revoked_reason} <- fetch_field(row, :revoked_reason),
         true <- valid_uuid_string?(id),
         true <- valid_uuid_string?(user_id),
         true <- kind in @entitlement_kinds,
         true <- valid_row_scope?(scope_key),
         true <- source_kind == :subscription,
         true <- valid_uuid_string?(source_id) and source_id == subscription_id,
         true <- status in @statuses,
         true <- match?(%DateTime{}, valid_from_at),
         true <- valid_datetime_or_nil?(valid_to_at),
         true <- valid_datetime_or_nil?(revoked_at),
         true <- valid_string_or_nil?(revoked_reason) do
      {:ok,
       %{
         id: id,
         user_id: user_id,
         kind: kind,
         scope_key: scope_key,
         source_kind: source_kind,
         source_id: source_id,
         status: status,
         valid_from_at: valid_from_at,
         valid_to_at: valid_to_at,
         revoked_at: revoked_at,
         revoked_reason: revoked_reason
       }}
    else
      _ -> :error
    end
  end

  defp normalize_source_row(_row, _subscription_id), do: :error

  defp fetch_field(row, key), do: Map.fetch(row, key)

  defp valid_row_scope?(scope_key) when is_binary(scope_key) do
    byte_size(scope_key) > 0 and String.valid?(scope_key)
  end

  defp valid_row_scope?(_scope_key), do: false

  defp valid_datetime_or_nil?(nil), do: true
  defp valid_datetime_or_nil?(%DateTime{}), do: true
  defp valid_datetime_or_nil?(_datetime), do: false

  defp valid_string_or_nil?(nil), do: true
  defp valid_string_or_nil?(value) when is_binary(value), do: String.valid?(value)
  defp valid_string_or_nil?(_value), do: false

  defp valid_uuid_string?(value) when is_binary(value) and byte_size(value) == 36 do
    match?({:ok, _raw16}, UUIDv7.decode(value))
  end

  defp valid_uuid_string?(_value), do: false

  defp unique_row_ids(rows) do
    raw_ids = Enum.map(rows, &UUIDv7.decode!(&1.id))

    if length(raw_ids) == length(Enum.uniq(raw_ids)), do: :ok, else: :error
  end

  defp matching_target_id(:empty, _input, _rows), do: {:ok, nil}

  defp matching_target_id(:pair, input, rows) do
    matching_rows = Enum.filter(rows, &matching_target?(&1, input))

    case matching_rows do
      [] -> {:ok, nil}
      [row] -> {:ok, row.id}
      _ -> :error
    end
  end

  defp matching_target?(row, input) do
    row.user_id == input.user_id and
      row.kind == input.entitlement_kind and
      row.scope_key == input.entitlement_scope_key and
      row.source_kind == :subscription and
      row.source_id == input.subscription_id
  end

  defp active_non_target_ids(:empty, _input, _matching_target_id, rows) do
    rows
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(& &1.id)
    |> sorted_unique_uuids()
  end

  defp active_non_target_ids(:pair, input, _matching_target_id, rows) do
    rows
    |> Enum.reject(fn row ->
      row.status != :active or matching_target?(row, input)
    end)
    |> Enum.map(& &1.id)
    |> sorted_unique_uuids()
  end

  defp sorted_unique_uuids(uuids) do
    if Enum.all?(uuids, &valid_uuid_string?/1) do
      {:ok, uuids |> BinaryUuidSort.sort_uuids() |> Enum.uniq()}
    else
      :error
    end
  end

  defp final_active_set_matches?(:empty, _input, nil, []), do: true
  defp final_active_set_matches?(:empty, _input, _target_grant_id, _rows), do: false

  defp final_active_set_matches?(:pair, input, target_grant_id, [selected_row])
       when is_binary(target_grant_id) do
    valid_uuid_string?(target_grant_id) and
      pair_row_matches?(input, target_grant_id, selected_row)
  end

  defp final_active_set_matches?(:pair, _input, _target_grant_id, _rows), do: false

  defp pair_row_matches?(input, target_grant_id, selected_row) do
    case normalize_source_row(selected_row, input.subscription_id) do
      {:ok, row} ->
        row.id == target_grant_id and
          row.user_id == input.user_id and
          row.kind == input.entitlement_kind and
          row.scope_key == input.entitlement_scope_key and
          row.source_kind == :subscription and
          row.source_id == input.subscription_id and
          row.status == :active and
          same_datetime?(row.valid_from_at, input.valid_from_at) and
          same_datetime?(row.valid_to_at, input.valid_until_at) and
          is_nil(row.revoked_at) and
          is_nil(row.revoked_reason)

      :error ->
        false
    end
  end

  defp same_datetime?(nil, nil), do: true

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  defp same_datetime?(_left, _right), do: false

  defp internal_error do
    {:error, Error.new("INTERNAL_ERROR", "subscription source convergence state is invalid")}
  end
end
