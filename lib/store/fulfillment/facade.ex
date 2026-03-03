defmodule Store.Fulfillment.Facade do
  @moduledoc """
  Consumer and system scoped fulfillment surfaces.
  """

  alias Store.Fulfillment
  alias Store.Fulfillment.FulfillmentOrder
  alias Store.Fulfillment.Queries.{AdminFulfillmentQueueQuery, AdminFulfillmentShowQuery}
  alias Store.Fulfillment.Shipment
  alias Store.Support.Errors.Normalize
  alias Store.Workers.EnsureFulfillmentForPaidOrderWorker

  @spec list_fulfillment_orders_for_admin(map(), AdminFulfillmentQueueQuery.t()) ::
          {:ok, [FulfillmentOrder.t()]} | {:error, term()}
  def list_fulfillment_orders_for_admin(actor, %AdminFulfillmentQueueQuery{} = query)
      when is_map(actor) do
    case Fulfillment.list_fulfillment_orders_for_admin(query, actor) do
      {:ok, fulfillment_orders} -> {:ok, fulfillment_orders}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec get_fulfillment_order_for_admin(map(), AdminFulfillmentShowQuery.t()) ::
          {:ok, FulfillmentOrder.t() | nil} | {:error, term()}
  def get_fulfillment_order_for_admin(actor, %AdminFulfillmentShowQuery{} = query)
      when is_map(actor) do
    case Fulfillment.get_fulfillment_order_for_admin(query, actor) do
      {:ok, fulfillment_order} -> {:ok, fulfillment_order}
      {:error, error} -> {:error, Normalize.normalize(error)}
    end
  end

  @spec mark_packed_for_support(map(), String.t()) ::
          {:ok, FulfillmentOrder.t()} | {:error, term()}
  def mark_packed_for_support(actor, fulfillment_order_id)
      when is_map(actor) and is_binary(fulfillment_order_id) do
    Fulfillment.mark_packed(fulfillment_order_id, actor)
    |> normalize_result()
  end

  @spec mark_shipped_for_support(map(), String.t(), map()) ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), shipment: Shipment.t()}}
          | {:error, term()}
  def mark_shipped_for_support(actor, fulfillment_order_id, shipment_attrs)
      when is_map(actor) and is_binary(fulfillment_order_id) and is_map(shipment_attrs) do
    Fulfillment.mark_shipped(fulfillment_order_id, shipment_attrs, actor)
    |> normalize_result()
  end

  @spec mark_delivered_for_support(map(), String.t()) ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), shipment: Shipment.t() | nil}}
          | {:error, term()}
  def mark_delivered_for_support(actor, fulfillment_order_id)
      when is_map(actor) and is_binary(fulfillment_order_id) do
    Fulfillment.mark_delivered(fulfillment_order_id, actor)
    |> normalize_result()
  end

  @spec cancel_fulfillment_for_admin(map(), String.t(), map()) ::
          {:ok, FulfillmentOrder.t()} | {:error, term()}
  def cancel_fulfillment_for_admin(actor, fulfillment_order_id, attrs \\ %{})
      when is_map(actor) and is_binary(fulfillment_order_id) and is_map(attrs) do
    Fulfillment.cancel(fulfillment_order_id, attrs, actor)
    |> normalize_result()
  end

  @spec ensure_paid_order_fulfillment_for_system(String.t()) ::
          {:ok, %{fulfillment_order: FulfillmentOrder.t(), idempotent?: boolean()}}
          | {:error, term()}
  def ensure_paid_order_fulfillment_for_system(order_id) when is_binary(order_id) do
    Fulfillment.ensure_fulfillment_for_paid_order(order_id, context: %{system?: true})
    |> normalize_result()
  end

  @spec enqueue_paid_order_fulfillment_for_system(String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_paid_order_fulfillment_for_system(order_id) when is_binary(order_id) do
    %{"order_id" => order_id}
    |> EnsureFulfillmentForPaidOrderWorker.new()
    |> Oban.insert()
  end

  @spec get_fulfillment_by_order_id_for_system(String.t()) ::
          {:ok, FulfillmentOrder.t() | nil} | {:error, term()}
  def get_fulfillment_by_order_id_for_system(order_id) when is_binary(order_id) do
    Fulfillment.get_fulfillment_by_order_id(order_id)
    |> normalize_result()
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}
end
