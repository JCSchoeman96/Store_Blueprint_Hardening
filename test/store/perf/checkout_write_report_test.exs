defmodule Store.Perf.CheckoutWriteReportTest do
  use ExUnit.Case, async: true

  alias Store.Perf.CheckoutWriteReport

  test "failure_fingerprint is stable for the same error shape" do
    row = %{
      step: :start_from_cart,
      error_code: "STALE_RECORD",
      exception_module: "Store.Support.Errors.Error",
      message: "checkout changed",
      checkout_stage: "draft_attach"
    }

    assert CheckoutWriteReport.failure_fingerprint(row) ==
             CheckoutWriteReport.failure_fingerprint(row)
  end

  test "summarize_step_rows includes bounded samples and grouped fingerprints" do
    row_a = %{
      step: :start_from_cart,
      status: :error,
      error_code: "STALE_RECORD",
      exception_module: "Store.Support.Errors.Error",
      message: "checkout changed",
      error_detail: String.duplicate("a", 800),
      checkout_stage: "draft_attach",
      user_index: 1,
      iteration: 2,
      variant_id: "var_1",
      duration_ms: 15.0,
      query_count: 3,
      queue_time_ms: 1.0,
      query_time_ms: 4.0,
      decode_time_ms: 0.5
    }

    row_b = %{row_a | user_index: 2, iteration: 3}
    row_ok = %{row_a | status: :ok, error_code: nil, exception_module: nil, message: nil}

    summary = CheckoutWriteReport.summarize_step_rows([row_a, row_b, row_ok], sample_cap: 1)

    assert summary.count == 3
    assert summary.success_count == 1
    assert summary.error_count == 2
    assert map_size(summary.error_fingerprints) == 1
    assert length(summary.sample_errors) == 1

    [sample] = summary.sample_errors
    assert sample.error_code == "STALE_RECORD"
    assert sample.checkout_stage == "draft_attach"
    assert String.length(sample.error_detail) == 600
  end
end
