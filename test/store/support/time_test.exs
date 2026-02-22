defmodule Store.Support.TimeTest do
  use ExUnit.Case, async: true

  alias Store.Support.Time

  test "minutes_to_usec converts minutes precisely" do
    assert Time.minutes_to_usec(0) == 0
    assert Time.minutes_to_usec(1) == 60_000_000
    assert Time.minutes_to_usec(15) == 900_000_000
  end

  test "within_window_usec? accepts only non-negative ages within the window" do
    now = 10_000_000

    assert Time.within_window_usec?(9_900_000, 200_000, now)
    refute Time.within_window_usec?(9_700_000, 200_000, now)
    refute Time.within_window_usec?(10_100_000, 200_000, now)
  end
end
