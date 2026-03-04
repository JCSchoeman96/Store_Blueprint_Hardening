defmodule Store.Subscriptions.SchedulerTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.Scheduler

  test "renewal_key is deterministic and period-specific" do
    subscription_id = "0192168f-0f4b-7df3-b1e8-f8ef8e19620a"
    period_end_at = DateTime.from_unix!(1_767_200_000)

    first = Scheduler.renewal_key(subscription_id, period_end_at)
    second = Scheduler.renewal_key(subscription_id, period_end_at)
    later = Scheduler.renewal_key(subscription_id, DateTime.add(period_end_at, 1, :day))

    assert first == second
    assert first != later
  end

  test "fixed_day_of_month plans clamp to end-of-month when anchor day is missing in target month" do
    period_start_at = DateTime.from_naive!(~N[2026-01-31 08:15:00], "Etc/UTC")

    plan = %{
      interval_unit: :month,
      interval_count: 1,
      anchor_mode: :fixed_day_of_month,
      anchor_day_of_month: 31,
      billing_timezone: "Etc/UTC"
    }

    period_end = Scheduler.advance_period_end(period_start_at, plan)

    assert period_end.year == 2026
    assert period_end.month == 2
    assert period_end.day == 28
  end

  test "start_anniversary monthly plans keep day for regular months" do
    period_start_at = DateTime.from_naive!(~N[2026-05-10 14:30:00], "Etc/UTC")
    plan = %{interval_unit: :month, interval_count: 1, anchor_mode: :start_anniversary}

    period_end = Scheduler.advance_period_end(period_start_at, plan)

    assert period_end.year == 2026
    assert period_end.month == 6
    assert period_end.day == 10
    assert period_end.hour == 14
    assert period_end.minute == 30
  end

  test "grace_expires_at adds grace_period_days in whole-day increments" do
    past_due_since = DateTime.from_naive!(~N[2026-01-01 00:00:00], "Etc/UTC")
    plan = %{grace_period_days: 5}

    assert DateTime.from_naive!(~N[2026-01-06 00:00:00], "Etc/UTC") ==
             Scheduler.grace_expires_at(past_due_since, plan)
  end
end
