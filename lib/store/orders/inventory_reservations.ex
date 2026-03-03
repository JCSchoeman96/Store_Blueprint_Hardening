defmodule Store.Orders.InventoryReservations do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Store.Catalog.{AvailabilityCache, InventoryItem, StockFastPath, Variant}
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

  @spec expire_reservations(DateTime.t(), keyword()) ::
          {:ok, %{expired_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def expire_reservations(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_expiry_batch_size)
    now = DateTime.truncate(now, :microsecond)

    Repo.transaction(fn ->
      candidates = expired_active_candidates(now, batch_size)

      variant_ids =
        candidates |> Enum.map(& &1.variant_id) |> Enum.uniq() |> BinaryUuidSort.sort_uuids()

      variant_ids
      |> Enum.reduce_while({0, []}, fn variant_id, acc ->
        expire_variant_step(variant_id, candidates, now, acc)
      end)
      |> finalize_expire_result()
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
    with :ok <- ensure_available(inventory_item, desired_qty),
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

  defp active_variant_ids_for_order(order_id) do
    InventoryReservation
    |> where([r], r.order_id == ^order_id and r.state == :active)
    |> Repo.all()
    |> Enum.map(& &1.variant_id)
    |> BinaryUuidSort.sort_uuids()
  end

  defp consume_variant_step(order_id, variant_id, now, {count, reservations}) do
    case consume_variant(order_id, variant_id, now) do
      {:ok, nil} ->
        {:cont, {count, reservations}}

      {:ok, reservation} ->
        {:cont, {count + 1, [reservation | reservations]}}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp consume_variant(order_id, variant_id, now) do
    with {:ok, inventory_item} <- lock_inventory_item(variant_id),
         {:ok, reservation} <- lock_order_variant_reservation(order_id, variant_id) do
      consume_locked_reservation(order_id, variant_id, reservation, inventory_item, now)
    end
  end

  defp consume_locked_reservation(
         _order_id,
         _variant_id,
         %InventoryReservation{state: :consumed},
         _inventory_item,
         _now
       ) do
    {:ok, nil}
  end

  defp consume_locked_reservation(
         _order_id,
         _variant_id,
         %InventoryReservation{state: :active} = reservation,
         inventory_item,
         now
       ) do
    with {:ok, _updated_inventory} <-
           update_inventory_counters(inventory_item, -reservation.quantity, -reservation.quantity) do
      update_reservation(reservation.id, %{state: :consumed, consumed_at: now})
    end
  end

  defp consume_locked_reservation(
         order_id,
         variant_id,
         %InventoryReservation{state: state},
         _inventory_item,
         _now
       ) do
    {:error,
     Error.new("RESERVATION_CONFLICT", "Reservation is not consumable", %{
       order_id: order_id,
       variant_id: variant_id,
       state: state
     })}
  end

  defp consume_locked_reservation(_order_id, _variant_id, nil, _inventory_item, _now),
    do: {:ok, nil}

  defp finalize_consume_result({count, reservations}) do
    %{consumed_count: count, reservations: Enum.reverse(reservations)}
  end

  defp expired_active_candidates(now, batch_size) do
    InventoryReservation
    |> where([r], r.state == :active and r.expires_at <= ^now)
    |> order_by([r], asc: r.expires_at, asc: r.id)
    |> limit(^batch_size)
    |> Repo.all()
  end

  defp expire_variant_step(variant_id, candidates, now, {count, reservations}) do
    variant_candidates = candidates_for_variant(candidates, variant_id)

    case lock_inventory_item(variant_id) do
      {:ok, _inventory_item} ->
        variant_candidates
        |> Enum.reduce_while({count, reservations}, fn reservation, inner ->
          expire_candidate_step(reservation.id, now, inner)
        end)
        |> then(fn updated -> {:cont, updated} end)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp candidates_for_variant(candidates, variant_id) do
    candidates
    |> Enum.filter(&(&1.variant_id == variant_id))
    |> Enum.sort_by(&{&1.expires_at, &1.id})
  end

  defp expire_candidate_step(reservation_id, now, {count, reservations}) do
    case expire_candidate(reservation_id, now) do
      {:ok, nil} ->
        {:cont, {count, reservations}}

      {:ok, reservation} ->
        {:cont, {count + 1, [reservation | reservations]}}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp expire_candidate(reservation_id, now) do
    case lock_expirable_reservation(reservation_id, now) do
      nil ->
        {:ok, nil}

      reservation ->
        expire_locked_reservation(reservation, now)
    end
  end

  defp lock_expirable_reservation(reservation_id, now) do
    InventoryReservation
    |> where([r], r.id == ^reservation_id and r.state == :active and r.expires_at <= ^now)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.one()
  end

  defp expire_locked_reservation(%InventoryReservation{} = reservation, now) do
    with {:ok, inventory_item} <- lock_inventory_item(reservation.variant_id),
         {:ok, _updated_inventory} <-
           update_inventory_counters(inventory_item, -reservation.quantity, 0) do
      update_reservation(reservation.id, %{state: :expired, expired_at: now})
    end
  end

  defp finalize_expire_result({count, reservations}) do
    %{expired_count: count, reservations: Enum.reverse(reservations)}
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
     Repo.get_by!(InventoryReservation,
       order_id: Map.fetch!(attrs, :order_id),
       variant_id: Map.fetch!(attrs, :variant_id)
     )}
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
      |> where([r], r.order_id == ^order_id and r.variant_id == ^variant_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    {:ok, reservation}
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

  defp consume_for_order_transaction(order_id, now) do
    case ensure_no_terminal_blockers(order_id) do
      :ok -> consume_active_variants(order_id, now)
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp consume_active_variants(order_id, now) do
    order_id
    |> active_variant_ids_for_order()
    |> Enum.reduce_while({0, []}, fn variant_id, acc ->
      consume_variant_step(order_id, variant_id, now, acc)
    end)
    |> finalize_consume_result()
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
