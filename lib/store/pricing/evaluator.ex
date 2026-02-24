defmodule Store.Pricing.Evaluator do
  @moduledoc """
  Pure deterministic pricing evaluator.

  This module has zero DB side effects. It evaluates deterministic pricing inputs,
  resolves stacking/tie-break rules, and returns canonical output suitable for
  immutable snapshot writes.
  """

  alias Store.Pricing.Contract

  alias Store.Pricing.Contract.{
    AppliedAdjustment,
    Candidate,
    Input,
    LineAllocation,
    LineEvaluation,
    Output
  }

  alias Store.Support.Errors.Error
  alias Store.Support.ID.BinaryUuidSort

  @type result :: {:ok, Output.t()} | {:error, Error.t()}

  @spec evaluate(Input.t() | map()) :: result()
  def evaluate(input) do
    input = Contract.to_input!(input)

    with :ok <- validate_input(input) do
      lines = sort_lines(input.lines)
      subtotal_minor = Enum.reduce(lines, 0, &(&1.line_total_minor + &2))

      selected_candidates = select_candidates(input)
      ordered_candidates = sort_applied_candidates(selected_candidates)

      applied_adjustments =
        ordered_candidates
        |> cap_candidates_to_subtotal(subtotal_minor)
        |> Enum.map(&to_applied_adjustment/1)

      discount_total_minor = Enum.reduce(applied_adjustments, 0, &(&1.discount_minor + &2))

      {line_allocations, allocated_discount_minor} =
        allocate_discount(lines, discount_total_minor)

      lines =
        lines
        |> Enum.map(fn line ->
          allocated_minor = allocation_for_line(line_allocations, line.id)

          %LineEvaluation{
            line_id: line.id,
            line_no: line.line_no,
            sku_snapshot: line.sku_snapshot,
            product_title_snapshot: line.product_title_snapshot,
            variant_title_snapshot: line.variant_title_snapshot,
            quantity: line.quantity,
            unit_price_minor: line.unit_price_minor,
            line_total_minor: line.line_total_minor,
            discount_allocated_minor: allocated_minor,
            net_line_total_minor: line.line_total_minor - allocated_minor
          }
        end)

      total_minor = max(subtotal_minor - allocated_discount_minor, 0)

      {:ok,
       %Output{
         currency: input.currency,
         subtotal_minor: subtotal_minor,
         discount_total_minor: allocated_discount_minor,
         total_minor: total_minor,
         lines: lines,
         line_allocations: line_allocations,
         applied_adjustments: applied_adjustments
       }}
    else
      {:error, _reason} = error -> error
    end
  rescue
    KeyError -> {:error, Error.new("VALIDATION_ERROR", "Missing required pricing input")}
    ArgumentError -> {:error, Error.new("VALIDATION_ERROR", "Invalid pricing input")}
  end

  @spec promotion_winner_tuple(Candidate.t()) :: tuple()
  def promotion_winner_tuple(%Candidate{} = candidate) do
    {
      -candidate.exclusive_priority,
      -candidate.discount_minor,
      datetime_sort_key(candidate.inserted_at),
      id_sort_key(candidate.id)
    }
  end

  @spec applied_adjustment_tuple(Candidate.t() | AppliedAdjustment.t()) :: tuple()
  def applied_adjustment_tuple(%Candidate{} = candidate) do
    {
      source_kind_sort_key(candidate.source_kind),
      candidate.precedence_rank,
      -candidate.discount_minor,
      datetime_sort_key(candidate.inserted_at),
      id_sort_key(candidate.id)
    }
  end

  def applied_adjustment_tuple(%AppliedAdjustment{} = adjustment) do
    {
      source_kind_sort_key(adjustment.source_kind),
      adjustment.precedence_rank,
      -adjustment.discount_minor,
      datetime_sort_key(adjustment.inserted_at),
      id_sort_key(adjustment.source_id)
    }
  end

  defp validate_input(%Input{as_of: %DateTime{}, currency: currency, lines: lines})
       when is_binary(currency) and currency != "" and is_list(lines) and lines != [] do
    if Enum.all?(lines, &valid_line?/1) do
      :ok
    else
      {:error, Error.new("VALIDATION_ERROR", "Invalid line input")}
    end
  end

  defp validate_input(_input),
    do: {:error, Error.new("VALIDATION_ERROR", "Invalid pricing evaluator input")}

  defp valid_line?(%Contract.Line{} = line) do
    is_integer(line.line_no) and line.line_no > 0 and
      is_integer(line.quantity) and line.quantity > 0 and
      is_integer(line.unit_price_minor) and line.unit_price_minor >= 0 and
      is_integer(line.line_total_minor) and line.line_total_minor >= 0
  end

  defp sort_lines(lines) do
    Enum.sort_by(lines, fn line -> {id_sort_key(line.id), line.line_no} end)
  end

  defp select_candidates(%Input{} = input) do
    eligible_coupon = maybe_eligible_coupon(input)

    eligible_promotions =
      input.promotions
      |> Enum.filter(&candidate_eligible?(&1, input.as_of, input.eligibility))

    {exclusive_winner, combinable_promotions} =
      resolve_promotion_candidates(eligible_promotions)

    case exclusive_winner do
      nil ->
        maybe_add_coupon(combinable_promotions, eligible_coupon)

      winner ->
        maybe_add_coupon([winner], coupon_if_allowed_with_exclusive(eligible_coupon))
    end
  end

  defp resolve_promotion_candidates(promotions) do
    exclusive_candidates = Enum.filter(promotions, &exclusive_candidate?/1)

    if exclusive_candidates == [] do
      combinable_promotions =
        promotions
        |> Enum.filter(&(!exclusive_candidate?(&1) and &1.combinable?))

      {nil, combinable_promotions}
    else
      winner =
        exclusive_candidates
        |> Enum.sort_by(&promotion_winner_tuple/1)
        |> List.first()

      {winner, []}
    end
  end

  defp exclusive_candidate?(%Candidate{} = candidate),
    do: candidate.exclusive? or not candidate.combinable?

  defp maybe_eligible_coupon(%Input{} = input) do
    case input.coupon do
      nil ->
        nil

      coupon ->
        if candidate_eligible?(coupon, input.as_of, input.eligibility), do: coupon, else: nil
    end
  end

  defp coupon_if_allowed_with_exclusive(nil), do: nil

  defp coupon_if_allowed_with_exclusive(%Candidate{} = coupon) do
    if coupon.allow_with_exclusive?, do: coupon, else: nil
  end

  defp maybe_add_coupon(candidates, nil), do: candidates
  defp maybe_add_coupon(candidates, coupon), do: [coupon | candidates]

  defp candidate_eligible?(%Candidate{} = candidate, %DateTime{} = as_of, eligibility) do
    candidate.active? and within_window?(candidate, as_of) and
      eligibility_passes?(candidate, eligibility)
  end

  defp within_window?(%Candidate{} = candidate, %DateTime{} = as_of) do
    starts_ok? =
      case candidate.starts_at do
        nil -> true
        %DateTime{} = starts_at -> DateTime.compare(as_of, starts_at) in [:eq, :gt]
      end

    ends_ok? =
      case candidate.ends_at do
        nil -> true
        %DateTime{} = ends_at -> DateTime.compare(as_of, ends_at) in [:eq, :lt]
      end

    starts_ok? and ends_ok?
  end

  defp eligibility_passes?(%Candidate{eligibility_key: nil}, _eligibility), do: true

  defp eligibility_passes?(%Candidate{eligibility_key: key}, eligibility)
       when is_map(eligibility) do
    Map.get(eligibility, key, Map.get(eligibility, to_string(key), false)) == true
  end

  defp eligibility_passes?(_candidate, _eligibility), do: false

  defp sort_applied_candidates(candidates) do
    Enum.sort_by(candidates, &applied_adjustment_tuple/1)
  end

  defp cap_candidates_to_subtotal(candidates, subtotal_minor) do
    {_remaining, applied} =
      Enum.reduce(candidates, {max(subtotal_minor, 0), []}, fn candidate, {remaining, acc} ->
        applied_minor = min(candidate.discount_minor, remaining)

        if applied_minor <= 0 do
          {remaining, acc}
        else
          {remaining - applied_minor, [%{candidate | discount_minor: applied_minor} | acc]}
        end
      end)

    Enum.reverse(applied)
  end

  defp to_applied_adjustment(%Candidate{} = candidate) do
    %AppliedAdjustment{
      source_kind: candidate.source_kind,
      source_id: candidate.id,
      source_code: candidate.code,
      discount_minor: candidate.discount_minor,
      precedence_rank: candidate.precedence_rank,
      inserted_at: candidate.inserted_at
    }
  end

  defp allocate_discount(lines, discount_total_minor) do
    eligible_lines = Enum.filter(lines, & &1.eligible?)
    eligible_lines = if eligible_lines == [], do: lines, else: eligible_lines

    eligible_subtotal = Enum.reduce(eligible_lines, 0, &(&1.line_total_minor + &2))

    allocatable_discount_minor =
      discount_total_minor
      |> min(eligible_subtotal)
      |> max(0)

    cond do
      allocatable_discount_minor == 0 or eligible_subtotal == 0 ->
        allocations = Enum.map(lines, &%LineAllocation{line_id: &1.id, discount_minor: 0})
        {allocations, 0}

      true ->
        ordered_eligible_lines = Enum.sort_by(eligible_lines, &id_sort_key(&1.id))

        {base_allocations, base_total} =
          Enum.reduce(ordered_eligible_lines, {%{}, 0}, fn line, {acc, total} ->
            minor = div(line.line_total_minor * allocatable_discount_minor, eligible_subtotal)
            {Map.put(acc, line.id, minor), total + minor}
          end)

        remainder = allocatable_discount_minor - base_total

        allocations_with_remainder =
          Enum.reduce(Enum.take(ordered_eligible_lines, remainder), base_allocations, fn line,
                                                                                         acc ->
            Map.update!(acc, line.id, &(&1 + 1))
          end)

        allocations =
          lines
          |> Enum.sort_by(&id_sort_key(&1.id))
          |> Enum.map(fn line ->
            %LineAllocation{
              line_id: line.id,
              discount_minor: Map.get(allocations_with_remainder, line.id, 0)
            }
          end)

        {allocations, allocatable_discount_minor}
    end
  end

  defp allocation_for_line(allocations, line_id) do
    allocations
    |> Enum.find(%LineAllocation{line_id: line_id, discount_minor: 0}, &(&1.line_id == line_id))
    |> Map.fetch!(:discount_minor)
  end

  defp source_kind_sort_key(kind), do: kind |> to_string() |> String.downcase()

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp id_sort_key(id), do: BinaryUuidSort.normalize_raw16!(id)
end
