defmodule Store.Orders.SnapshotWriter do
  @moduledoc """
  Create-only writer for priced immutable order snapshot evidence.

  This module never updates existing snapshot rows. If a snapshot already exists
  for an order, writes are treated as idempotent no-op reads.
  """

  import Ash.Expr
  require Ash.Query

  alias Store.Orders.{OrderAdjustment, OrderLineItem}
  alias Store.Pricing.Contract
  alias Store.Pricing.Evaluator
  alias Store.Support.Errors.Error

  @type write_result ::
          {:ok,
           %{
             line_items: [OrderLineItem.t()],
             adjustments: [OrderAdjustment.t()],
             idempotent?: boolean()
           }}
          | {:error, Error.t()}

  @spec write_priced_snapshot(String.t(), Contract.Output.t() | map(), keyword()) ::
          write_result()
  def write_priced_snapshot(order_id, output, opts \\ [])
      when is_binary(order_id) and is_list(opts) do
    output = to_output!(output)

    case read_existing_snapshot(order_id) do
      {:ok, existing_line_items, existing_adjustments} ->
        maybe_write_snapshot(order_id, output, existing_line_items, existing_adjustments, opts)

      {:error, _reason} = error ->
        error
    end
  rescue
    KeyError -> {:error, Error.new("VALIDATION_ERROR", "Invalid priced snapshot output")}
    ArgumentError -> {:error, Error.new("VALIDATION_ERROR", "Invalid priced snapshot output")}
  end

  defp maybe_write_snapshot(_order_id, _output, existing_line_items, existing_adjustments, _opts)
       when existing_line_items != [] or existing_adjustments != [] do
    {:ok,
     %{
       line_items: Enum.sort_by(existing_line_items, & &1.line_no),
       adjustments: Enum.sort_by(existing_adjustments, & &1.sequence_no),
       idempotent?: true
     }}
  end

  defp maybe_write_snapshot(order_id, %Contract.Output{} = output, [], [], opts) do
    ash_opts = Keyword.merge([domain: Store.Orders, authorize?: false], opts)

    with {:ok, line_items} <- create_line_items(order_id, output, ash_opts),
         {:ok, adjustments} <- create_adjustments(order_id, output, ash_opts) do
      {:ok,
       %{
         line_items: Enum.sort_by(line_items, & &1.line_no),
         adjustments: Enum.sort_by(adjustments, & &1.sequence_no),
         idempotent?: false
       }}
    end
  end

  defp create_line_items(order_id, %Contract.Output{} = output, ash_opts) do
    created =
      output.lines
      |> Enum.sort_by(& &1.line_no)
      |> Enum.map(fn line ->
        attrs = %{
          order_id: order_id,
          line_no: line.line_no,
          currency: output.currency,
          quantity: line.quantity,
          unit_price_minor: line.unit_price_minor,
          line_total_minor: line.line_total_minor,
          sku_snapshot: line.sku_snapshot,
          product_title_snapshot: line.product_title_snapshot,
          variant_title_snapshot: line.variant_title_snapshot,
          discount_allocated_minor: line.discount_allocated_minor,
          net_line_total_minor: line.net_line_total_minor
        }

        OrderLineItem
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(ash_opts)
      end)

    collect_create_results(created, "Unable to persist line-item snapshot")
  end

  defp create_adjustments(order_id, %Contract.Output{} = output, ash_opts) do
    created =
      output.applied_adjustments
      |> Enum.sort_by(&Evaluator.applied_adjustment_tuple/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {adjustment, sequence_no} ->
        attrs = %{
          order_id: order_id,
          sequence_no: sequence_no,
          currency: output.currency,
          kind: "pricing_discount",
          amount_minor: -adjustment.discount_minor,
          reason: "#{adjustment.source_kind}:#{adjustment.source_code || "N/A"}",
          source_kind: adjustment.source_kind |> to_string() |> String.downcase(),
          source_code: adjustment.source_code,
          source_id: adjustment.source_id,
          precedence_rank: adjustment.precedence_rank
        }

        OrderAdjustment
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(ash_opts)
      end)

    collect_create_results(created, "Unable to persist adjustment snapshot")
  end

  defp collect_create_results(results, error_message) do
    case Enum.split_with(results, &match?({:ok, _record}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, record} -> record end)}
      {_oks, _errors} -> {:error, Error.new("INTERNAL_ERROR", error_message)}
    end
  end

  defp read_existing_line_items(order_id) do
    target_order_id = order_id
    query = Ash.Query.filter(OrderLineItem, expr(order_id == ^target_order_id))

    case Ash.read(query, domain: Store.Orders, context: %{system?: true}, authorize?: false) do
      {:ok, records} ->
        {:ok, records}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read line-item snapshot")}
    end
  end

  defp read_existing_adjustments(order_id) do
    target_order_id = order_id
    query = Ash.Query.filter(OrderAdjustment, expr(order_id == ^target_order_id))

    case Ash.read(query, domain: Store.Orders, context: %{system?: true}, authorize?: false) do
      {:ok, records} ->
        {:ok, records}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "Unable to read adjustment snapshot")}
    end
  end

  defp to_output!(%Contract.Output{} = output), do: output

  defp to_output!(attrs) when is_map(attrs) do
    struct!(Contract.Output, attrs)
  end

  defp read_existing_snapshot(order_id) do
    with {:ok, line_items} <- read_existing_line_items(order_id),
         {:ok, adjustments} <- read_existing_adjustments(order_id) do
      {:ok, line_items, adjustments}
    end
  end
end
