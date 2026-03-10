defmodule Store.Perf.ChaosProfileTest do
  use ExUnit.Case, async: true

  alias Store.Perf.ChaosProfile

  test "same seed and request key produce stable provider delays" do
    seed = "phase30-chaos"
    request_key = "checkout_sessions:pi_local_123"

    delay_one =
      ChaosProfile.standard_provider_delay_ms(
        :mobile_realistic,
        seed,
        "checkout_sessions",
        request_key
      )

    delay_two =
      ChaosProfile.standard_provider_delay_ms(
        :mobile_realistic,
        seed,
        "checkout_sessions",
        request_key
      )

    assert delay_one == delay_two
    assert delay_one in 150..3_000
  end

  test "different request keys spread across multiple latency buckets" do
    delays =
      1..32
      |> Enum.map(fn index ->
        ChaosProfile.standard_provider_delay_ms(
          :mobile_realistic,
          "phase30-chaos",
          "payment_intents",
          "payment_intents:pi_local_#{index}"
        )
      end)

    assert Enum.min(delays) >= 150
    assert Enum.max(delays) <= 3_000
    assert delays |> Enum.uniq() |> length() > 8
  end

  test "provider incident fault delays stay in the expected envelopes" do
    assert ChaosProfile.fault_delay_ms(
             :provider_incident,
             :slow,
             "phase30-chaos",
             "payment_intents:pi_local_slow",
             500
           ) in 200..3_000

    assert ChaosProfile.fault_delay_ms(
             :provider_incident,
             :timeout,
             "phase30-chaos",
             "payment_intents:pi_local_timeout",
             500
           ) in 2_000..3_000
  end

  test "browser latency and report paths are profile-specific" do
    assert ChaosProfile.browser_latency_ms(:baseline) == 0
    assert ChaosProfile.browser_latency_ms(:mobile_realistic) == 400
    assert ChaosProfile.browser_latency_ms(:provider_incident) == 700

    assert ChaosProfile.report_path(:baseline) == "tmp/perf/performance_smoke_report.json"

    assert ChaosProfile.report_path(:mobile_realistic) ==
             "tmp/perf/performance_smoke_report_mobile_realistic.json"
  end
end
