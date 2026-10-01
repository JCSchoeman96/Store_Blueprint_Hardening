defmodule Store.Orders.InventoryReservations do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Store.Catalog.{AvailabilityCache, InventoryItem, StockFastPath, Variant}
  alias Store.Orders.InventoryAdmission.Request
  alias Store.Orders.InventoryReservation
  alias Store.Repo
  alias Store.Support.Errors.Error
  alias Store.Support.ID.{BinaryUuidSort, UUIDv7}

  @default_reservation_ttl_seconds 15 * 60
  @default_expiry_batch_size 500

  @spec reserve_inventory(String.t(), [map()], keyword()) ::
          {:ok, %{reservations: [InventoryReservation.t()], inventory_items: [InventoryItem.t()]}}
          | {:error, term()}
  def reserve_inventory(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    case normalize_reserve_items(items) do
      {:ok, desired_quantities} ->
        now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
        ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_reservation_ttl_seconds)
        expires_at = DateTime.add(now, ttl_seconds, :second)
        variant_ids = desired_quantities |> Map.keys() |> BinaryUuidSort.sort_uuids()

        Repo.transaction(fn ->
          reserve_variants(order_id, variant_ids, desired_quantities, expires_at, now)
        end)
        |> unwrap_transaction_error("Reservation transaction failed")
        |> maybe_invalidate_after_reserve()

      {:error, error} ->
        {:error, error}
    end
  rescue
    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid reserve input", %{})}
  end

  @spec reserve_inventory_for_checkout(String.t(), [map()], keyword()) ::
          {:ok, %{reserved_rows: [map()]}} | {:error, term()}
  def reserve_inventory_for_checkout(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    case normalize_reserve_items(items) do
      {:ok, desired_quantities} ->
        now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)
        ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_reservation_ttl_seconds)
        expires_at = DateTime.add(now, ttl_seconds, :second)

        requests =
          desired_quantities
          |> Map.to_list()
          |> Enum.sort_by(fn {variant_id, _quantity} ->
            BinaryUuidSort.normalize_raw16!(variant_id)
          end)
          |> Enum.with_index(1)
          |> Enum.map(fn {{variant_id, quantity}, ordinal} ->
            %{
              reservation_id: UUIDv7.generate(),
              reservation_key: reservation_key(order_id, variant_id),
              variant_id: variant_id,
              quantity: quantity,
              ordinal: ordinal
            }
          end)

        run_checkout_reservation_transaction(order_id, requests, expires_at, now)
        |> unwrap_transaction_error("Checkout reservation transaction failed")
        |> maybe_invalidate_after_checkout_reserve(requests)

      {:error, error} ->
        {:error, error}
    end
  rescue
    ArgumentError ->
      {:error, Error.new("VALIDATION_ERROR", "Invalid reserve input", %{})}
  end

  @spec reserve_exact_generation(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             reservation: InventoryReservation.t(),
             inventory_item: InventoryItem.t(),
             replayed?: boolean()
           }}
          | {:error, term()}
  def reserve_exact_generation(order_id, variant_id, reservation_key, quantity, opts \\ [])

  def reserve_exact_generation(order_id, variant_id, reservation_key, quantity, opts)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_integer(quantity) and quantity > 0 and is_list(opts) do
    with {:ok, identity} <- exact_generation_identity(order_id, variant_id, reservation_key),
         {:ok, _now, expires_at} <- exact_reservation_window(opts) do
      reserve_exact_generation_transactional(identity, quantity, expires_at)
    end
  rescue
    _error -> {:error, Error.new("RESERVATION_CONFLICT", "Exact reservation failed", %{})}
  end

  def reserve_exact_generation(_order_id, _variant_id, _reservation_key, _quantity, _opts),
    do: {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact reservation input", %{})}

  @spec recover_exact_generation(String.t(), String.t(), String.t()) ::
          :not_found
          | {:ok, {:found, map()}}
          | {:error, :contradictory_evidence | :database_unavailable | :invalid_identity}
  def recover_exact_generation(order_id, variant_id, reservation_key)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) do
    case exact_generation_identity(order_id, variant_id, reservation_key) do
      {:ok, identity} -> read_exact_generation(identity)
      {:error, _error} -> {:error, :invalid_identity}
    end
  rescue
    _error -> {:error, :database_unavailable}
  end

  def recover_exact_generation(_order_id, _variant_id, _reservation_key),
    do: {:error, :invalid_identity}

  @spec release_exact_generation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{reservation: InventoryReservation.t() | nil, changed?: boolean()}}
          | {:error, term()}
  def release_exact_generation(order_id, variant_id, reservation_key, opts \\ [])

  def release_exact_generation(order_id, variant_id, reservation_key, opts)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_list(opts) do
    with {:ok, identity} <- exact_generation_identity(order_id, variant_id, reservation_key),
         {:ok, now} <- exact_operation_now(opts) do
      mutate_exact_generation(identity, now, :release)
    end
  rescue
    _error -> {:error, Error.new("RESERVATION_CONFLICT", "Exact reservation release failed", %{})}
  end

  def release_exact_generation(_order_id, _variant_id, _reservation_key, _opts),
    do: {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact release input", %{})}

  @spec consume_exact_generation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{reservation: InventoryReservation.t() | nil, changed?: boolean()}}
          | {:error, term()}
  def consume_exact_generation(order_id, variant_id, reservation_key, opts \\ [])

  def consume_exact_generation(order_id, variant_id, reservation_key, opts)
      when is_binary(order_id) and is_binary(variant_id) and is_binary(reservation_key) and
             is_list(opts) do
    with {:ok, identity} <- exact_generation_identity(order_id, variant_id, reservation_key),
         {:ok, now} <- exact_operation_now(opts) do
      mutate_exact_generation(identity, now, :consume)
    end
  rescue
    _error -> {:error, Error.new("RESERVATION_CONFLICT", "Exact reservation consume failed", %{})}
  end

  def consume_exact_generation(_order_id, _variant_id, _reservation_key, _opts),
    do: {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact consume input", %{})}

  defp exact_generation_identity(order_id, variant_id, reservation_key) do
    with {:ok, normalized_order_id} <- normalize_variant_id(order_id),
         {:ok, normalized_variant_id} <- normalize_variant_id(variant_id),
         {:ok,
          {:renewal_generation,
           %{order_id: ^normalized_order_id, variant_id: ^normalized_variant_id} = identities}} <-
           Request.classify_reservation_key(reservation_key) do
      {:ok,
       %{
         order_id: identities.order_id,
         variant_id: identities.variant_id,
         reservation_key: reservation_key
       }}
    else
      _ ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "Exact key does not match expected order and variant",
           %{
             order_id: order_id,
             variant_id: variant_id
           }
         )}
    end
  end

  defp exact_reservation_window(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:now, :ttl_seconds] == [] do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_reservation_ttl_seconds)

      if match?(%DateTime{}, now) and is_integer(ttl_seconds) and ttl_seconds >= 0 do
        now = DateTime.truncate(now, :microsecond)
        {:ok, now, DateTime.add(now, ttl_seconds, :second)}
      else
        {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact reservation window", %{})}
      end
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact reservation options", %{})}
    end
  end

  defp exact_operation_now(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:now] == [] do
      case Keyword.get(opts, :now, DateTime.utc_now()) do
        %DateTime{} = now -> {:ok, DateTime.truncate(now, :microsecond)}
        _ -> {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact operation time", %{})}
      end
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Invalid exact operation options", %{})}
    end
  end

  defp read_exact_generation(identity) do
    reservation =
      InventoryReservation
      |> where([r], r.reservation_key == ^identity.reservation_key)
      |> Repo.one()

    classify_exact_recovery_row(reservation, identity)
  end

  defp classify_exact_recovery_row(nil, _identity), do: :not_found

  defp classify_exact_recovery_row(%InventoryReservation{} = row, identity) do
    if row.order_id == identity.order_id and row.variant_id == identity.variant_id do
      {:ok, {:found, reservation_facts(row)}}
    else
      {:error, :contradictory_evidence}
    end
  end

  defp reserve_exact_generation_transactional(identity, quantity, expires_at) do
    result =
      Repo.transaction(fn ->
        case reserve_exact_generation_transaction(identity, quantity, expires_at) do
          {:ok, reservation, inventory_item, replayed?} ->
            {reservation, inventory_item, replayed?}

          {:error, error} ->
            Repo.rollback(error)
        end
      end)

    case result do
      {:ok, {reservation, inventory_item, replayed?}} ->
        unless replayed?, do: invalidate_variant_availability([identity.variant_id])

        {:ok, %{reservation: reservation, inventory_item: inventory_item, replayed?: replayed?}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp mutate_exact_generation(identity, now, action) do
    result =
      Repo.transaction(fn ->
        case exact_generation_transaction(identity, now, action) do
          {:ok, reservation, changed?} -> {reservation, changed?}
          {:error, error} -> Repo.rollback(error)
        end
      end)

    case result do
      {:ok, {reservation, changed?}} ->
        if changed?, do: invalidate_variant_availability([identity.variant_id])
        {:ok, %{reservation: reservation, changed?: changed?}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp exact_generation_transaction(identity, now, :release),
    do: release_exact_generation_transaction(identity, now)

  defp exact_generation_transaction(identity, now, :consume),
    do: consume_exact_generation_transaction(identity, now)

  defp reserve_exact_generation_transaction(identity, quantity, expires_at) do
    case lock_inventory_item(identity.variant_id) do
      {:ok, inventory_item} ->
        reserve_exact_with_locked_inventory(
          inventory_item,
          identity,
          quantity,
          expires_at
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp reserve_exact_with_locked_inventory(inventory_item, identity, quantity, expires_at) do
    case lock_exact_generation_reservation(identity) do
      {:ok, %InventoryReservation{} = existing} ->
        validate_exact_reservation_replay(existing, identity, quantity, inventory_item)

      {:ok, nil} ->
        insert_new_exact_generation(inventory_item, identity, quantity, expires_at)
    end
  end

  defp insert_new_exact_generation(inventory_item, identity, quantity, expires_at) do
    with {:ok, active_reservation} <-
           lock_active_pair_reservation(identity.order_id, identity.variant_id),
         :ok <- ensure_no_other_active_reservation(active_reservation, identity),
         :ok <- ensure_available(inventory_item, quantity),
         {:ok, updated_inventory} <- update_inventory_counters(inventory_item, quantity, 0),
         {:ok, inserted_reservation} <-
           insert_reservation(%{
             order_id: identity.order_id,
             variant_id: identity.variant_id,
             reservation_key: identity.reservation_key,
             quantity: quantity,
             state: :active,
             expires_at: expires_at
           }) do
      {:ok, inserted_reservation, updated_inventory, false}
    end
  end

  defp validate_exact_reservation_replay(reservation, identity, quantity, inventory_item) do
    cond do
      reservation.order_id != identity.order_id or
        reservation.variant_id != identity.variant_id or
          reservation.reservation_key != identity.reservation_key ->
        {:error,
         exact_reservation_conflict("Exact reservation evidence is contradictory", identity)}

      reservation.state == :active and reservation.quantity == quantity ->
        {:ok, reservation, inventory_item, true}

      reservation.state == :active ->
        {:error,
         exact_reservation_conflict("Exact active reservation quantity differs", identity)}

      true ->
        {:error,
         exact_reservation_conflict(
           "Terminal reservation generations cannot be reactivated",
           identity
         )}
    end
  end

  defp ensure_no_other_active_reservation(nil, _identity), do: :ok

  defp ensure_no_other_active_reservation(%InventoryReservation{} = reservation, identity) do
    {:error,
     exact_reservation_conflict(
       "Another reservation generation is already active for this order and variant",
       Map.put(identity, :active_reservation_id, reservation.id)
     )}
  end

  defp release_exact_generation_transaction(identity, now) do
    with {:ok, inventory_item} <- lock_inventory_item(identity.variant_id),
         {:ok, reservation} <- lock_exact_generation_reservation(identity),
         :ok <- validate_exact_row_identity(reservation, identity) do
      case reservation do
        nil ->
          {:ok, nil, false}

        %InventoryReservation{state: :active} = active ->
          release_active_exact_reservation(inventory_item, active, now)

        %InventoryReservation{state: state} = terminal
        when state in [:cancelled, :expired, :consumed] ->
          {:ok, terminal, false}

        %InventoryReservation{state: state} ->
          {:error,
           exact_reservation_conflict("Exact reservation cannot be released from this state", %{
             state: state
           })}
      end
    end
  end

  defp release_active_exact_reservation(inventory_item, active, now) do
    with {:ok, _updated_inventory} <-
           update_inventory_counters(inventory_item, -active.quantity, 0),
         {:ok, cancelled} <-
           update_reservation(active.id, %{state: :cancelled, cancelled_at: now}) do
      {:ok, cancelled, true}
    end
  end

  defp consume_exact_generation_transaction(identity, now) do
    with {:ok, inventory_item} <- lock_inventory_item(identity.variant_id),
         {:ok, reservation} <- lock_exact_generation_reservation(identity),
         :ok <- validate_exact_row_identity(reservation, identity) do
      case reservation do
        nil ->
          {:ok, nil, false}

        %InventoryReservation{state: :consumed} = consumed ->
          {:ok, consumed, false}

        %InventoryReservation{state: :active} = active ->
          consume_active_exact_reservation(inventory_item, active, now)

        %InventoryReservation{state: state} ->
          {:error,
           exact_reservation_conflict("Exact reservation cannot be consumed from this state", %{
             state: state
           })}
      end
    end
  end

  defp consume_active_exact_reservation(inventory_item, active, now) do
    with {:ok, _updated_inventory} <-
           update_inventory_counters(inventory_item, -active.quantity, -active.quantity),
         {:ok, consumed} <-
           update_reservation(active.id, %{state: :consumed, consumed_at: now}) do
      {:ok, consumed, true}
    end
  end

  defp validate_exact_row_identity(nil, _identity), do: :ok

  defp validate_exact_row_identity(%InventoryReservation{} = reservation, identity) do
    if reservation.order_id == identity.order_id and reservation.variant_id == identity.variant_id and
         reservation.reservation_key == identity.reservation_key do
      :ok
    else
      {:error,
       exact_reservation_conflict("Exact reservation evidence is contradictory", identity)}
    end
  end

  defp lock_exact_generation_reservation(identity) do
    reservation =
      InventoryReservation
      |> where([r], r.reservation_key == ^identity.reservation_key)
      |> lock("FOR UPDATE")
      |> Repo.one()

    {:ok, reservation}
  end

  defp lock_active_pair_reservation(order_id, variant_id) do
    reservation =
      InventoryReservation
      |> where(
        [r],
        r.order_id == ^order_id and r.variant_id == ^variant_id and r.state == :active
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    {:ok, reservation}
  end

  defp reservation_facts(%InventoryReservation{} = reservation) do
    Map.take(Map.from_struct(reservation), [
      :id,
      :order_id,
      :variant_id,
      :reservation_key,
      :quantity,
      :state,
      :expires_at,
      :consumed_at,
      :expired_at,
      :cancelled_at,
      :version
    ])
  end

  defp exact_reservation_conflict(message, details) do
    Error.new("RESERVATION_CONFLICT", message, details)
  end

  defp run_checkout_reservation_transaction(order_id, requests, expires_at, now) do
    Repo.transaction(fn ->
      case reserve_inventory_cte(order_id, requests, expires_at, now) do
        {:ok, rows} ->
          ensure_checkout_reservation_match!(requests, rows)
          %{reserved_rows: rows}

        {:error, %Error{} = error} ->
          Repo.rollback(error)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @spec consume_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{consumed_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def consume_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    Repo.transaction(fn -> consume_for_order_transaction(order_id, now) end)
    |> unwrap_transaction_result()
    |> maybe_invalidate_after_consume_or_expire()
  end

  @spec release_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{released_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def release_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    Repo.transaction(fn -> release_for_order_transaction(order_id, now) end)
    |> unwrap_transaction_result()
    |> maybe_invalidate_after_consume_or_expire()
  end

  @spec expire_reservations(DateTime.t(), keyword()) ::
          {:ok, %{expired_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def expire_reservations(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_expiry_batch_size)
    now = DateTime.truncate(now, :microsecond)

    Repo.transaction(fn ->
      candidates = expired_active_candidates(now, batch_size)

      case expire_candidates_transaction(candidates, now) do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> unwrap_transaction_result()
    |> maybe_invalidate_after_consume_or_expire()
  end

  defp reserve_variants(order_id, variant_ids, desired_quantities, expires_at, now) do
    variant_ids
    |> Enum.reduce_while(%{reservations: [], inventory_items: []}, fn variant_id, acc ->
      desired_qty = Map.fetch!(desired_quantities, variant_id)

      case reserve_variant(order_id, variant_id, desired_qty, expires_at, now) do
        {:ok, reservation, inventory_item} ->
          {:cont, append_reserve_result(acc, reservation, inventory_item)}

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> finalize_reserve_result()
  end

  defp append_reserve_result(acc, reservation, inventory_item) do
    reservations =
      if is_nil(reservation) do
        acc.reservations
      else
        [reservation | acc.reservations]
      end

    %{
      reservations: reservations,
      inventory_items: [inventory_item | acc.inventory_items]
    }
  end

  defp finalize_reserve_result(result) do
    %{
      reservations: Enum.reverse(result.reservations),
      inventory_items: Enum.reverse(result.inventory_items)
    }
  end

  defp reserve_variant(order_id, variant_id, desired_qty, expires_at, now) do
    with {:ok, inventory_item} <- lock_inventory_item(variant_id),
         {:ok, reservation} <- lock_order_variant_reservation(order_id, variant_id) do
      reserve_locked_variant(
        order_id,
        variant_id,
        desired_qty,
        expires_at,
        now,
        inventory_item,
        reservation
      )
    end
  end

  defp reserve_locked_variant(_order_id, _variant_id, 0, _expires_at, _now, inventory_item, nil) do
    {:ok, nil, inventory_item}
  end

  defp reserve_locked_variant(
         order_id,
         variant_id,
         desired_qty,
         expires_at,
         _now,
         inventory_item,
         nil
       ) do
    with :ok <- ensure_no_other_active_generic_pair_reservation(order_id, variant_id, desired_qty),
         :ok <- ensure_available(inventory_item, desired_qty),
         {:ok, updated_inventory} <- update_inventory_counters(inventory_item, desired_qty, 0),
         {:ok, reservation} <-
           insert_reservation(%{
             order_id: order_id,
             variant_id: variant_id,
             reservation_key: reservation_key(order_id, variant_id),
             quantity: desired_qty,
             state: :active,
             expires_at: expires_at
           }) do
      {:ok, reservation, updated_inventory}
    end
  end

  defp reserve_locked_variant(
         _order_id,
         _variant_id,
         desired_qty,
         expires_at,
         now,
         inventory_item,
         %InventoryReservation{state: :active} = reservation
       ) do
    adjust_active_reservation(reservation, desired_qty, expires_at, inventory_item, now)
  end

  defp reserve_locked_variant(
         _order_id,
         _variant_id,
         0,
         _expires_at,
         _now,
         inventory_item,
         %InventoryReservation{} = reservation
       ) do
    {:ok, reservation, inventory_item}
  end

  defp reserve_locked_variant(
         order_id,
         variant_id,
         _desired_qty,
         _expires_at,
         _now,
         _inventory_item,
         %InventoryReservation{state: state}
       ) do
    {:error,
     Error.new("RESERVATION_CONFLICT", "Reservation is no longer active", %{
       order_id: order_id,
       variant_id: variant_id,
       state: state
     })}
  end

  defp adjust_active_reservation(reservation, desired_qty, expires_at, inventory_item, now) do
    delta = desired_qty - reservation.quantity

    cond do
      delta > 0 ->
        increase_active_reservation(reservation, desired_qty, delta, expires_at, inventory_item)

      delta < 0 and desired_qty == 0 ->
        cancel_active_reservation(reservation, delta, inventory_item, now)

      delta < 0 ->
        decrease_active_reservation(reservation, desired_qty, delta, expires_at, inventory_item)

      desired_qty == 0 ->
        cancel_without_counter_change(reservation, inventory_item, now)

      true ->
        refresh_active_expiry(reservation, inventory_item, expires_at)
    end
  end

  defp increase_active_reservation(reservation, desired_qty, delta, expires_at, inventory_item) do
    with :ok <- ensure_available(inventory_item, delta),
         {:ok, updated_inventory} <- update_inventory_counters(inventory_item, delta, 0),
         {:ok, updated_reservation} <-
           update_reservation(reservation.id, %{
             quantity: desired_qty,
             expires_at: expires_at
           }) do
      {:ok, updated_reservation, updated_inventory}
    end
  end

  defp decrease_active_reservation(reservation, desired_qty, delta, expires_at, inventory_item) do
    with {:ok, updated_inventory} <- update_inventory_counters(inventory_item, delta, 0),
         {:ok, updated_reservation} <-
           update_reservation(reservation.id, %{
             quantity: desired_qty,
             expires_at: expires_at
           }) do
      {:ok, updated_reservation, updated_inventory}
    end
  end

  defp cancel_active_reservation(reservation, delta, inventory_item, now) do
    with {:ok, updated_inventory} <- update_inventory_counters(inventory_item, delta, 0),
         {:ok, updated_reservation} <-
           update_reservation(reservation.id, %{
             quantity: 0,
             state: :cancelled,
             cancelled_at: now
           }) do
      {:ok, updated_reservation, updated_inventory}
    end
  end

  defp cancel_without_counter_change(reservation, inventory_item, now) do
    with {:ok, updated_reservation} <-
           update_reservation(reservation.id, %{state: :cancelled, cancelled_at: now}) do
      {:ok, updated_reservation, inventory_item}
    end
  end

  defp refresh_active_expiry(reservation, inventory_item, expires_at) do
    with {:ok, updated_reservation} <-
           update_reservation(reservation.id, %{expires_at: expires_at}) do
      {:ok, updated_reservation, inventory_item}
    end
  end

  defp ensure_no_terminal_blockers(order_id) do
    blocker_exists? =
      InventoryReservation
      |> where([r], r.order_id == ^order_id and r.state in [:expired, :cancelled])
      |> where_generic_reservation_key()
      |> Repo.exists?()

    if blocker_exists? do
      {:error,
       Error.new("RESERVATION_CONFLICT", "Order has non-consumable reservations", %{
         order_id: order_id
       })}
    else
      :ok
    end
  end

  defp active_generic_reservations_for_order(order_id) do
    InventoryReservation
    |> where([r], r.order_id == ^order_id and r.state == :active)
    |> where_generic_reservation_key()
    |> order_by([r], asc: r.variant_id, asc: r.id)
    |> Repo.all()
  end

  defp release_for_order_transaction(order_id, now) do
    candidates = active_generic_reservations_for_order(order_id)

    case mutate_generic_reservations(candidates, :cancelled, now) do
      {:ok, reservations} ->
        %{released_count: length(reservations), reservations: reservations}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp mutate_generic_reservations([], _target_state, _now), do: {:ok, []}

  defp mutate_generic_reservations(candidates, target_state, now) do
    variant_ids =
      candidates |> Enum.map(& &1.variant_id) |> Enum.uniq() |> BinaryUuidSort.sort_uuids()

    with {:ok, inventory_items} <- lock_inventory_items(variant_ids),
         {:ok, reservations} <- lock_generic_reservations(candidates),
         {:ok, reserved_delta, stock_delta} <- mutation_counter_deltas(target_state),
         :ok <-
           apply_inventory_counter_deltas(
             inventory_items,
             reservations,
             reserved_delta,
             stock_delta
           ) do
      transition_reservations(reservations, target_state, now)
    end
  end

  defp mutation_counter_deltas(:cancelled), do: {:ok, -1, 0}
  defp mutation_counter_deltas(:expired), do: {:ok, -1, 0}
  defp mutation_counter_deltas(:consumed), do: {:ok, -1, -1}

  defp lock_inventory_items([]), do: {:ok, []}

  defp lock_inventory_items(variant_ids) do
    inventory_items =
      InventoryItem
      |> where([i], i.variant_id in ^variant_ids)
      |> order_by([i], asc: i.variant_id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    found_ids = MapSet.new(inventory_items, & &1.variant_id)
    missing_ids = Enum.reject(variant_ids, &MapSet.member?(found_ids, &1))

    if missing_ids == [] do
      {:ok, inventory_items}
    else
      {:error,
       Error.new("OUT_OF_STOCK", "Inventory item missing or out of stock", %{
         variant_ids: missing_ids
       })}
    end
  end

  defp lock_generic_reservations([]), do: {:ok, []}

  defp lock_generic_reservations(candidates) do
    reservation_keys = Enum.map(candidates, & &1.reservation_key)

    rows =
      InventoryReservation
      |> where([r], r.reservation_key in ^reservation_keys)
      |> where_generic_reservation_key()
      |> order_by([r], asc: r.variant_id, asc: r.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    candidate_evidence =
      MapSet.new(candidates, &{&1.id, &1.order_id, &1.variant_id, &1.reservation_key})

    locked_evidence =
      MapSet.new(rows, &{&1.id, &1.order_id, &1.variant_id, &1.reservation_key})

    if MapSet.equal?(candidate_evidence, locked_evidence) and
         Enum.all?(rows, &(&1.state == :active)) do
      {:ok, rows}
    else
      {:error,
       Error.new("RESERVATION_CONFLICT", "Generic reservations changed before mutation", %{})}
    end
  end

  defp apply_inventory_counter_deltas([], [], _reserved_multiplier, _stock_multiplier),
    do: :ok

  defp apply_inventory_counter_deltas(
         inventory_items,
         reservations,
         reserved_multiplier,
         stock_multiplier
       ) do
    quantities_by_variant =
      reservations
      |> Enum.group_by(& &1.variant_id, & &1.quantity)
      |> Map.new(fn {variant_id, quantities} -> {variant_id, Enum.sum(quantities)} end)

    inventory_by_variant = Map.new(inventory_items, &{&1.variant_id, &1})

    deltas =
      quantities_by_variant
      |> Enum.map(fn {variant_id, quantity} ->
        {variant_id, quantity * reserved_multiplier, quantity * stock_multiplier}
      end)
      |> Enum.sort_by(fn {variant_id, _reserved_delta, _stock_delta} ->
        BinaryUuidSort.normalize_raw16!(variant_id)
      end)

    if Enum.all?(deltas, &counter_delta_non_negative?(&1, inventory_by_variant)) do
      update_inventory_counters_in_bulk(deltas)
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Inventory counters would go below zero", %{})}
    end
  end

  defp counter_delta_non_negative?(
         {variant_id, reserved_delta, stock_delta},
         inventory_by_variant
       ) do
    item = Map.fetch!(inventory_by_variant, variant_id)
    item.reserved_count + reserved_delta >= 0 and item.stock_on_hand + stock_delta >= 0
  end

  defp update_inventory_counters_in_bulk(deltas) do
    variant_ids = Enum.map(deltas, fn {variant_id, _, _} -> UUIDv7.decode!(variant_id) end)
    reserved_deltas = Enum.map(deltas, fn {_, reserved_delta, _} -> reserved_delta end)
    stock_deltas = Enum.map(deltas, fn {_, _, stock_delta} -> stock_delta end)

    sql = """
    UPDATE inventory_items AS inventory
    SET
      reserved_count = inventory.reserved_count + delta.reserved_delta,
      stock_on_hand = inventory.stock_on_hand + delta.stock_delta,
      version = inventory.version + 1
    FROM unnest($1::uuid[], $2::bigint[], $3::bigint[])
      AS delta(variant_id, reserved_delta, stock_delta)
    WHERE inventory.variant_id = delta.variant_id
    RETURNING inventory.variant_id
    """

    case Repo.query(sql, [variant_ids, reserved_deltas, stock_deltas]) do
      {:ok, %{rows: rows}} when length(rows) == length(deltas) ->
        :ok

      {:ok, _result} ->
        {:error,
         Error.new("RESERVATION_CONFLICT", "Inventory counter update was incomplete", %{})}

      {:error, _reason} ->
        {:error, Error.new("RESERVATION_CONFLICT", "Inventory counter update failed", %{})}
    end
  end

  defp transition_reservations([], _target_state, _now), do: {:ok, []}

  defp transition_reservations(reservations, target_state, now) do
    reservation_ids = Enum.map(reservations, & &1.id)

    timestamp_field =
      case target_state do
        :cancelled -> :cancelled_at
        :expired -> :expired_at
        :consumed -> :consumed_at
      end

    set_attrs =
      %{state: target_state, updated_at: now}
      |> Map.put(timestamp_field, now)

    {updated_count, _updated_rows} =
      InventoryReservation
      |> where([r], r.id in ^reservation_ids and r.state == :active)
      |> Repo.update_all(
        set: Map.to_list(set_attrs),
        inc: [version: 1]
      )

    if updated_count == length(reservation_ids) do
      updated_rows =
        InventoryReservation
        |> where([r], r.id in ^reservation_ids)
        |> order_by([r], asc: r.variant_id, asc: r.id)
        |> Repo.all()

      {:ok, updated_rows}
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Reservation transition was incomplete", %{})}
    end
  end

  defp expired_active_candidates(now, batch_size) do
    InventoryReservation
    |> where([r], r.state == :active and r.expires_at <= ^now)
    |> where_generic_reservation_key()
    |> order_by([r], asc: r.expires_at, asc: r.id)
    |> limit(^batch_size)
    |> Repo.all()
  end

  defp expire_candidates_transaction([], _now),
    do: {:ok, %{expired_count: 0, reservations: []}}

  defp expire_candidates_transaction(candidates, now) do
    candidate_ids = Enum.map(candidates, & &1.id)

    candidate_variant_ids =
      candidates |> Enum.map(& &1.variant_id) |> Enum.uniq() |> BinaryUuidSort.sort_uuids()

    with {:ok, inventory_items} <- lock_inventory_items(candidate_variant_ids),
         {:ok, reservations} <- lock_expirable_candidates(candidate_ids, now),
         {:ok, updated_reservations} <-
           mutate_expired_reservations(inventory_items, reservations, now) do
      reservations = Enum.sort_by(updated_reservations, &{&1.expires_at, &1.id})
      {:ok, %{expired_count: length(reservations), reservations: reservations}}
    end
  end

  defp lock_expirable_candidates([], _now), do: {:ok, []}

  defp lock_expirable_candidates(candidate_ids, now) do
    rows =
      InventoryReservation
      |> where([r], r.id in ^candidate_ids and r.state == :active and r.expires_at <= ^now)
      |> where_generic_reservation_key()
      |> order_by([r], asc: r.variant_id, asc: r.expires_at, asc: r.id)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.all()

    {:ok, rows}
  end

  defp mutate_expired_reservations(_inventory_items, [], _now), do: {:ok, []}

  defp mutate_expired_reservations(inventory_items, reservations, now) do
    with {:ok, reserved_multiplier, stock_multiplier} <- mutation_counter_deltas(:expired),
         :ok <-
           apply_inventory_counter_deltas(
             inventory_items,
             reservations,
             reserved_multiplier,
             stock_multiplier
           ) do
      transition_reservations(reservations, :expired, now)
    end
  end

  defp update_inventory_counters(inventory_item, reserved_delta, stock_delta) do
    new_reserved_count = inventory_item.reserved_count + reserved_delta
    new_stock_on_hand = inventory_item.stock_on_hand + stock_delta

    cond do
      new_reserved_count < 0 ->
        {:error,
         Error.new("RESERVATION_CONFLICT", "Reserved count would go below zero", %{
           variant_id: inventory_item.variant_id
         })}

      new_stock_on_hand < 0 ->
        {:error,
         Error.new("RESERVATION_CONFLICT", "Stock on hand would go below zero", %{
           variant_id: inventory_item.variant_id
         })}

      true ->
        {updated_count, _} =
          InventoryItem
          |> where([i], i.id == ^inventory_item.id)
          |> Repo.update_all(
            set: [reserved_count: new_reserved_count, stock_on_hand: new_stock_on_hand],
            inc: [version: 1]
          )

        if updated_count == 1 do
          {:ok, Repo.get!(InventoryItem, inventory_item.id)}
        else
          {:error, Error.new("RESERVATION_CONFLICT", "Failed to update inventory counters", %{})}
        end
    end
  end

  defp update_reservation(reservation_id, attrs) do
    attrs = Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    {updated_count, _} =
      InventoryReservation
      |> where([r], r.id == ^reservation_id)
      |> Repo.update_all(set: Map.to_list(attrs), inc: [version: 1])

    if updated_count == 1 do
      {:ok, Repo.get!(InventoryReservation, reservation_id)}
    else
      {:error, Error.new("RESERVATION_CONFLICT", "Failed to update reservation", %{})}
    end
  end

  defp insert_reservation(attrs) do
    InventoryReservation
    |> struct()
    |> Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, reservation} ->
        maybe_reload_reservation(reservation, attrs)

      {:error, _changeset} ->
        {:error, Error.new("RESERVATION_CONFLICT", "Failed to create reservation", attrs)}
    end
  end

  defp maybe_reload_reservation(%InventoryReservation{id: nil}, attrs) do
    {:ok,
     Repo.get_by!(InventoryReservation, reservation_key: Map.fetch!(attrs, :reservation_key))}
  end

  defp maybe_reload_reservation(reservation, _attrs), do: {:ok, reservation}

  defp lock_inventory_item(variant_id) do
    item =
      InventoryItem
      |> where([i], i.variant_id == ^variant_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case item do
      nil ->
        {:error,
         Error.new("OUT_OF_STOCK", "Inventory item missing or out of stock", %{
           variant_id: variant_id
         })}

      value ->
        {:ok, value}
    end
  end

  defp lock_order_variant_reservation(order_id, variant_id) do
    reservation =
      InventoryReservation
      |> where([r], r.reservation_key == ^reservation_key(order_id, variant_id))
      |> lock("FOR UPDATE")
      |> Repo.one()

    case reservation do
      %InventoryReservation{order_id: ^order_id, variant_id: ^variant_id} ->
        {:ok, reservation}

      %InventoryReservation{} ->
        {:error,
         Error.new(
           "RESERVATION_CONFLICT",
           "Generic reservation key has contradictory identity",
           %{
             order_id: order_id,
             variant_id: variant_id
           }
         )}

      nil ->
        {:ok, nil}
    end
  end

  defp ensure_no_other_active_generic_pair_reservation(_order_id, _variant_id, 0), do: :ok

  defp ensure_no_other_active_generic_pair_reservation(order_id, variant_id, _quantity) do
    case lock_active_pair_reservation(order_id, variant_id) do
      {:ok, nil} ->
        :ok

      {:ok, %InventoryReservation{} = reservation} ->
        if reservation.reservation_key == reservation_key(order_id, variant_id) do
          :ok
        else
          {:error,
           Error.new(
             "RESERVATION_CONFLICT",
             "Another reservation generation is already active",
             %{
               order_id: order_id,
               variant_id: variant_id,
               active_reservation_id: reservation.id
             }
           )}
        end
    end
  end

  defp where_generic_reservation_key(query) do
    where(
      query,
      [r],
      fragment(
        "? = 'order:' || ?::text || ':sku:' || ?::text",
        r.reservation_key,
        r.order_id,
        r.variant_id
      )
    )
  end

  defp ensure_available(%InventoryItem{allow_oversell: true}, _required_delta), do: :ok

  defp ensure_available(%InventoryItem{} = item, required_delta) when required_delta >= 0 do
    available = item.stock_on_hand - item.reserved_count

    if available >= required_delta do
      :ok
    else
      {:error,
       Error.new("OUT_OF_STOCK", "Insufficient available inventory", %{
         variant_id: item.variant_id,
         available: available,
         requested_delta: required_delta
       })}
    end
  end

  defp normalize_reserve_items(items) do
    items
    |> Enum.reduce_while({:ok, %{}}, fn item, {:ok, acc} ->
      case normalize_item(item) do
        {:ok, variant_id, quantity} ->
          {:cont,
           {:ok, Map.update(acc, variant_id, quantity, fn existing -> existing + quantity end)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_item(item) when is_map(item) do
    variant_id = fetch_item_value(item, :variant_id)
    quantity = fetch_item_value(item, :quantity)

    cond do
      not is_binary(variant_id) ->
        {:error, Error.new("VALIDATION_ERROR", "variant_id must be a UUID string", %{item: item})}

      not is_integer(quantity) ->
        {:error, Error.new("VALIDATION_ERROR", "quantity must be an integer", %{item: item})}

      quantity < 0 ->
        {:error, Error.new("VALIDATION_ERROR", "quantity must be non-negative", %{item: item})}

      true ->
        normalize_variant_id(variant_id)
        |> case do
          {:ok, normalized_variant_id} -> {:ok, normalized_variant_id, quantity}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp normalize_item(item),
    do: {:error, Error.new("VALIDATION_ERROR", "each reserve item must be a map", %{item: item})}

  defp normalize_variant_id(variant_id) do
    normalized_variant_id = variant_id |> BinaryUuidSort.normalize_raw16!() |> UUIDv7.encode!()
    {:ok, normalized_variant_id}
  rescue
    _ ->
      {:error,
       Error.new("VALIDATION_ERROR", "variant_id must be a valid UUID", %{
         variant_id: variant_id
       })}
  end

  defp fetch_item_value(item, key) when is_map(item) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(item, key) -> Map.get(item, key)
      Map.has_key?(item, string_key) -> Map.get(item, string_key)
      true -> nil
    end
  end

  defp reservation_key(order_id, variant_id), do: "order:#{order_id}:sku:#{variant_id}"

  defp reserve_inventory_cte(order_id, requests, expires_at, now) do
    reservation_ids = Enum.map(requests, &UUIDv7.decode!(&1.reservation_id))
    variant_ids = Enum.map(requests, &UUIDv7.decode!(&1.variant_id))
    quantities = Enum.map(requests, & &1.quantity)
    ordinals = Enum.map(requests, & &1.ordinal)
    reservation_keys = Enum.map(requests, & &1.reservation_key)
    order_id = UUIDv7.decode!(order_id)

    sql = """
    WITH requested AS (
      SELECT *
      FROM unnest(
        $1::uuid[],
        $2::uuid[],
        $3::int[],
        $4::int[],
        $5::text[]
      ) AS r(reservation_id, variant_id, quantity, ordinal, reservation_key)
    ),
    locked AS (
      SELECT
        r.reservation_id,
        r.variant_id,
        r.quantity,
        r.ordinal,
        r.reservation_key,
        i.id AS inventory_item_id
      FROM requested r
      JOIN inventory_items i ON i.variant_id = r.variant_id
      ORDER BY r.ordinal
      FOR UPDATE OF i
    ),
    updated AS (
      UPDATE inventory_items AS i
      SET
        reserved_count = i.reserved_count + l.quantity,
        version = i.version + 1,
        updated_at = $8::timestamp
      FROM locked l
      WHERE i.id = l.inventory_item_id
        AND (i.allow_oversell = true OR i.stock_on_hand - i.reserved_count >= l.quantity)
      RETURNING
        l.reservation_id,
        l.variant_id,
        l.quantity,
        l.ordinal,
        l.reservation_key,
        i.id AS inventory_item_id,
        i.stock_on_hand,
        i.reserved_count,
        i.allow_oversell
    ),
    inserted AS (
      INSERT INTO inventory_reservations (
        id,
        order_id,
        variant_id,
        reservation_key,
        quantity,
        state,
        expires_at,
        version,
        inserted_at,
        updated_at
      )
      SELECT
        u.reservation_id,
        $6::uuid,
        u.variant_id,
        u.reservation_key,
        u.quantity,
        'active',
        $7::timestamp,
        1,
        $8::timestamp,
        $8::timestamp
      FROM updated u
      RETURNING id, variant_id
    )
    SELECT
      u.reservation_id::text,
      u.variant_id::text,
      u.quantity,
      u.ordinal,
      u.inventory_item_id::text,
      u.stock_on_hand,
      u.reserved_count,
      u.allow_oversell
    FROM updated u
    JOIN inserted i ON i.id = u.reservation_id AND i.variant_id = u.variant_id
    ORDER BY u.ordinal
    """

    case Repo.query(sql, [
           reservation_ids,
           variant_ids,
           quantities,
           ordinals,
           reservation_keys,
           order_id,
           expires_at,
           now
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             reservation_id,
                             variant_id,
                             quantity,
                             ordinal,
                             inventory_item_id,
                             stock_on_hand,
                             reserved_count,
                             allow_oversell
                           ] ->
           %{
             reservation_id: reservation_id,
             variant_id: variant_id,
             quantity: quantity,
             ordinal: ordinal,
             inventory_item_id: inventory_item_id,
             stock_on_hand: stock_on_hand,
             reserved_count: reserved_count,
             allow_oversell: allow_oversell
           }
         end)}

      {:error, _reason} ->
        {:error, Error.new("RESERVATION_CONFLICT", "Failed to reserve checkout inventory")}
    end
  end

  defp ensure_checkout_reservation_match!(requests, rows) do
    requested_by_variant = Map.new(requests, &{&1.variant_id, &1.quantity})
    reserved_by_variant = Map.new(rows, &{&1.variant_id, &1.quantity})

    unavailable =
      requested_by_variant
      |> Enum.reduce([], fn {variant_id, requested_qty}, acc ->
        reserved_qty = Map.get(reserved_by_variant, variant_id, 0)

        if reserved_qty == requested_qty do
          acc
        else
          [
            %{
              variant_id: variant_id,
              requested_quantity: requested_qty,
              reserved_quantity: reserved_qty
            }
            | acc
          ]
        end
      end)
      |> Enum.reverse()

    if unavailable == [] do
      :ok
    else
      Repo.rollback(
        Error.new("OUT_OF_STOCK", "Insufficient available inventory", %{
          unavailable_variants: unavailable,
          unavailable_variant_ids: Enum.map(unavailable, & &1.variant_id)
        })
      )
    end
  end

  defp consume_for_order_transaction(order_id, now) do
    case ensure_no_terminal_blockers(order_id) do
      :ok ->
        candidates = active_generic_reservations_for_order(order_id)

        case mutate_generic_reservations(candidates, :consumed, now) do
          {:ok, reservations} ->
            %{consumed_count: length(reservations), reservations: reservations}

          {:error, error} ->
            Repo.rollback(error)
        end

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp unwrap_transaction_error({:ok, result}, _message), do: {:ok, result}
  defp unwrap_transaction_error({:error, %Error{} = error}, _message), do: {:error, error}

  defp unwrap_transaction_error({:error, error}, message) do
    {:error, Error.new("RESERVATION_CONFLICT", message, %{error: inspect(error)})}
  end

  defp unwrap_transaction_result({:ok, result}), do: {:ok, result}
  defp unwrap_transaction_result({:error, error}), do: {:error, error}

  defp maybe_invalidate_after_reserve({:ok, %{inventory_items: inventory_items} = result}) do
    variant_ids = Enum.map(inventory_items, & &1.variant_id)
    invalidate_variant_availability(variant_ids)
    {:ok, result}
  end

  defp maybe_invalidate_after_reserve({:error, _} = error), do: error

  defp maybe_invalidate_after_checkout_reserve({:ok, %{reserved_rows: _rows} = result}, requests) do
    requests
    |> Enum.map(& &1.variant_id)
    |> invalidate_variant_availability()

    {:ok, result}
  end

  defp maybe_invalidate_after_checkout_reserve({:error, _} = error, _requests), do: error

  defp maybe_invalidate_after_consume_or_expire({:ok, %{reservations: reservations} = result}) do
    variant_ids = Enum.map(reservations, & &1.variant_id)
    invalidate_variant_availability(variant_ids)
    {:ok, result}
  end

  defp maybe_invalidate_after_consume_or_expire({:error, _} = error), do: error

  defp invalidate_variant_availability(variant_ids) do
    variant_ids =
      variant_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    _ = StockFastPath.invalidate_variant_ids(variant_ids)

    product_ids =
      Variant
      |> where([variant], variant.id in ^variant_ids)
      |> select([variant], variant.product_id)
      |> Repo.all()
      |> Enum.uniq()

    _ = AvailabilityCache.invalidate_products(product_ids)

    :ok
  end
end
