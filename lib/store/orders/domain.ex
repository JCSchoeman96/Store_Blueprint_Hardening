defmodule Store.Orders do
  @moduledoc """
  Orders domain for lifecycle state-machine resources and inventory reservations.
  """

  use Ash.Domain

  alias Store.Orders.{InventoryReservation, InventoryReservations, Order, SnapshotWriter}
  alias Store.Pricing.Contract
  alias Store.Support.ID.OrderRef

  @max_order_ref_attempts 5

  resources do
    resource(Store.Orders.Order)
    resource(Store.Orders.OrderLineItem)
    resource(Store.Orders.OrderAdjustment)
    resource(Store.Orders.InventoryReservation)
  end

  @spec create_order(map(), keyword()) :: {:ok, Order.t()} | {:error, term()}
  def create_order(attrs \\ %{}, opts \\ []) when is_map(attrs) and is_list(opts) do
    generator = Keyword.get(opts, :order_ref_generator, &OrderRef.generate/0)
    max_attempts = Keyword.get(opts, :max_attempts, @max_order_ref_attempts)
    ash_opts = Keyword.drop(opts, [:order_ref_generator, :max_attempts])

    do_create_order(attrs, generator, ash_opts, max_attempts)
  end

  @spec write_priced_snapshot(String.t(), Contract.Output.t() | map(), keyword()) ::
          {:ok,
           %{
             line_items: [Store.Orders.OrderLineItem.t()],
             adjustments: [Store.Orders.OrderAdjustment.t()]
           }}
          | {:error, term()}
  def write_priced_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    SnapshotWriter.write_priced_snapshot(order_id, output, opts)
  end

  @spec reserve_inventory(String.t(), [map()], keyword()) ::
          {:ok,
           %{
             reservations: [InventoryReservation.t()],
             inventory_items: [Store.Catalog.InventoryItem.t()]
           }}
          | {:error, term()}
  def reserve_inventory(order_id, items, opts \\ [])
      when is_binary(order_id) and is_list(items) and is_list(opts) do
    InventoryReservations.reserve_inventory(order_id, items, opts)
  end

  @spec consume_reservations_for_order(String.t(), keyword()) ::
          {:ok, %{consumed_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def consume_reservations_for_order(order_id, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    InventoryReservations.consume_reservations_for_order(order_id, opts)
  end

  @spec expire_reservations(DateTime.t(), keyword()) ::
          {:ok, %{expired_count: non_neg_integer(), reservations: [InventoryReservation.t()]}}
          | {:error, term()}
  def expire_reservations(now \\ DateTime.utc_now(), opts \\ [])
      when is_struct(now, DateTime) and is_list(opts) do
    InventoryReservations.expire_reservations(now, opts)
  end

  defp do_create_order(_attrs, _generator, _ash_opts, attempts) when attempts <= 0 do
    {:error, "unable to generate unique order_ref after retry limit"}
  end

  defp do_create_order(attrs, generator, ash_opts, attempts) do
    attrs_with_order_ref =
      if explicit_order_ref?(attrs) do
        attrs
      else
        Map.put(attrs, :order_ref, generator.())
      end

    result =
      Order
      |> Ash.Changeset.for_create(:create, attrs_with_order_ref)
      |> Ash.create(Keyword.merge([domain: __MODULE__, authorize?: false], ash_opts))

    cond do
      retryable_order_ref_conflict?(result, attrs) and attempts > 1 ->
        do_create_order(attrs, generator, ash_opts, attempts - 1)

      retryable_order_ref_conflict?(result, attrs) ->
        {:error, "unable to generate unique order_ref after retry limit"}

      true ->
        result
    end
  end

  defp retryable_order_ref_conflict?({:error, error}, attrs) do
    not explicit_order_ref?(attrs) and order_ref_conflict?(error)
  end

  defp retryable_order_ref_conflict?(_, _attrs), do: false

  defp explicit_order_ref?(attrs),
    do: Map.has_key?(attrs, :order_ref) or Map.has_key?(attrs, "order_ref")

  defp order_ref_conflict?(error) do
    message = Exception.message(error)
    String.contains?(message, "order_ref") and String.contains?(message, "already been taken")
  end
end
