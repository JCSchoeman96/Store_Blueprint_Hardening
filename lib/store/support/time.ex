defmodule Store.Support.Time do
  @moduledoc """
  Time helpers for governance-critical duration checks.

  Internal duration logic uses monotonic microseconds.
  """

  @usec_per_sec 1_000_000

  @spec now_mono_usec() :: integer()
  def now_mono_usec, do: System.monotonic_time(:microsecond)

  @spec minutes_to_usec(non_neg_integer()) :: non_neg_integer()
  def minutes_to_usec(minutes) when is_integer(minutes) and minutes >= 0 do
    minutes * 60 * @usec_per_sec
  end

  @spec within_window_usec?(integer(), non_neg_integer()) :: boolean()
  def within_window_usec?(issued_at_mono_usec, window_usec) do
    within_window_usec?(issued_at_mono_usec, window_usec, now_mono_usec())
  end

  @spec within_window_usec?(integer(), non_neg_integer(), integer()) :: boolean()
  def within_window_usec?(issued_at_mono_usec, window_usec, now_mono_usec)
      when is_integer(issued_at_mono_usec) and is_integer(window_usec) and window_usec >= 0 and
             is_integer(now_mono_usec) do
    age = now_mono_usec - issued_at_mono_usec
    age >= 0 and age <= window_usec
  end

  def within_window_usec?(_, _, _), do: false
end
