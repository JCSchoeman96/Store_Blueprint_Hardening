defmodule Store.Subscriptions.Scheduler do
  @moduledoc """
  Pure subscription period and renewal scheduling helpers.
  """

  @spec renewal_key(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def renewal_key(subscription_id, %DateTime{} = period_end_at) when is_binary(subscription_id) do
    "sub:#{subscription_id}:end:#{DateTime.to_iso8601(period_end_at)}"
  end

  @spec initial_period(DateTime.t(), map()) ::
          %{
            current_period_start_at: DateTime.t(),
            current_period_end_at: DateTime.t(),
            next_renewal_at: DateTime.t()
          }
  def initial_period(%DateTime{} = started_at, plan) when is_map(plan) do
    period_end_at = advance_period_end(started_at, plan)

    %{
      current_period_start_at: started_at,
      current_period_end_at: period_end_at,
      next_renewal_at: period_end_at
    }
  end

  @spec next_period(DateTime.t(), map()) ::
          %{
            current_period_start_at: DateTime.t(),
            current_period_end_at: DateTime.t(),
            next_renewal_at: DateTime.t()
          }
  def next_period(%DateTime{} = current_period_end_at, plan) when is_map(plan) do
    next_period_end_at = advance_period_end(current_period_end_at, plan)

    %{
      current_period_start_at: current_period_end_at,
      current_period_end_at: next_period_end_at,
      next_renewal_at: next_period_end_at
    }
  end

  @spec grace_expires_at(DateTime.t(), map()) :: DateTime.t()
  def grace_expires_at(%DateTime{} = past_due_since_at, plan) when is_map(plan) do
    grace_period_days =
      Map.get(plan, :grace_period_days) || Map.get(plan, "grace_period_days") || 0

    DateTime.add(past_due_since_at, grace_period_days * 86_400, :second)
  end

  @spec next_retry_at(DateTime.t(), non_neg_integer(), map()) :: DateTime.t()
  def next_retry_at(%DateTime{} = reference_at, dunning_attempt_count, plan)
      when is_integer(dunning_attempt_count) and dunning_attempt_count >= 0 and is_map(plan) do
    retry_schedule_hours =
      map_attr(plan, :retry_schedule_hours, [24, 72, 120])
      |> normalize_retry_schedule()

    schedule_index = min(dunning_attempt_count, max(length(retry_schedule_hours) - 1, 0))

    offset_hours =
      retry_schedule_hours
      |> Enum.at(schedule_index, List.last(retry_schedule_hours, 24))
      |> max(24)

    DateTime.add(reference_at, offset_hours * 3_600, :second)
  end

  @spec renewal_jitter_seconds(Ecto.UUID.t(), pos_integer()) :: non_neg_integer()
  def renewal_jitter_seconds(subscription_id, max_window_seconds \\ 3_600)

  def renewal_jitter_seconds(subscription_id, max_window_seconds)
      when is_binary(subscription_id) and is_integer(max_window_seconds) and
             max_window_seconds > 0 do
    hashed_source =
      case Ecto.UUID.dump(subscription_id) do
        {:ok, raw16} -> raw16
        :error -> subscription_id
      end

    :erlang.phash2(hashed_source, max_window_seconds + 1)
  end

  @spec advance_period_end(DateTime.t(), map()) :: DateTime.t()
  def advance_period_end(%DateTime{} = period_start_at, plan) when is_map(plan) do
    interval_unit = map_attr(plan, :interval_unit, :month)
    interval_count = map_attr(plan, :interval_count, 1)
    anchor_mode = map_attr(plan, :anchor_mode, :start_anniversary)
    anchor_day_of_month = map_attr(plan, :anchor_day_of_month, nil)
    billing_timezone = map_attr(plan, :billing_timezone, "Etc/UTC")
    day_seconds = interval_count * 86_400

    case interval_unit do
      :day ->
        DateTime.add(period_start_at, day_seconds, :second)

      :month ->
        shift_calendar_months(
          period_start_at,
          interval_count,
          anchor_mode,
          anchor_day_of_month,
          billing_timezone
        )

      :year ->
        shift_calendar_months(
          period_start_at,
          interval_count * 12,
          anchor_mode,
          anchor_day_of_month,
          billing_timezone
        )

      _ ->
        DateTime.add(period_start_at, day_seconds, :second)
    end
  end

  defp map_attr(plan, key, default) do
    Map.get(plan, key) || Map.get(plan, Atom.to_string(key)) || default
  end

  defp normalize_retry_schedule(schedule) when is_list(schedule) do
    schedule
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> case do
      [] -> [24, 72, 120]
      values -> values
    end
  end

  defp normalize_retry_schedule(_schedule), do: [24, 72, 120]

  defp shift_calendar_months(
         %DateTime{} = period_start_at,
         month_count,
         anchor_mode,
         anchor_day_of_month,
         billing_timezone
       ) do
    local = shift_zone!(period_start_at, billing_timezone)
    local_date = DateTime.to_date(local)
    local_time = DateTime.to_time(local)

    anchor_day =
      case anchor_mode do
        :fixed_day_of_month when is_integer(anchor_day_of_month) -> anchor_day_of_month
        _ -> local_date.day
      end

    shifted_date = shift_date_months(local_date, month_count, anchor_day)

    shifted_local =
      case DateTime.new(shifted_date, local_time, local.time_zone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, datetime, _after} -> datetime
      end

    shift_zone!(shifted_local, "Etc/UTC")
  end

  defp shift_date_months(%Date{} = date, month_count, anchor_day) when is_integer(month_count) do
    month_index = date.year * 12 + (date.month - 1) + month_count
    year = div(month_index, 12)
    month = rem(month_index, 12) + 1
    day = min(anchor_day, days_in_month(year, month))
    Date.new!(year, month, day)
  end

  defp days_in_month(year, month) do
    Date.new!(year, month, 1)
    |> Date.days_in_month()
  end

  defp shift_zone!(%DateTime{} = datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end
end
