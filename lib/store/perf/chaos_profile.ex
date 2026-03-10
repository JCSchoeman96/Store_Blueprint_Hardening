defmodule Store.Perf.ChaosProfile do
  @moduledoc false

  @type profile :: :baseline | :mobile_realistic | :provider_incident
  @type fault_mode :: :slow | :timeout | :error

  @profiles [:baseline, :mobile_realistic, :provider_incident]
  @default_seed "store-perf-chaos"
  @bucket_scale 10_000

  @mobile_realistic_distribution [
    {7_000, {150, 350}},
    {9_000, {350, 900}},
    {9_800, {900, 1_800}},
    {10_000, {2_500, 3_000}}
  ]

  @provider_incident_distribution [
    {5_500, {200, 500}},
    {8_500, {800, 1_600}},
    {10_000, {2_000, 3_000}}
  ]

  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @spec current_profile() :: profile()
  def current_profile do
    normalize_profile(System.get_env("STORE_PERF_CHAOS_PROFILE"))
  end

  @spec current_seed() :: String.t()
  def current_seed do
    case System.get_env("STORE_PERF_CHAOS_SEED") do
      nil -> @default_seed
      "" -> @default_seed
      seed -> seed
    end
  end

  @spec normalize_profile(term()) :: profile()
  def normalize_profile(value) when value in @profiles, do: value
  def normalize_profile("baseline"), do: :baseline
  def normalize_profile("mobile_realistic"), do: :mobile_realistic
  def normalize_profile("provider_incident"), do: :provider_incident
  def normalize_profile(_value), do: :baseline

  @spec report_path(profile()) :: String.t()
  def report_path(:baseline), do: "tmp/perf/performance_smoke_report.json"
  def report_path(profile), do: "tmp/perf/performance_smoke_report_#{profile}.json"

  @spec browser_latency_ms(profile()) :: non_neg_integer()
  def browser_latency_ms(:baseline), do: 0
  def browser_latency_ms(:mobile_realistic), do: 400
  def browser_latency_ms(:provider_incident), do: 700

  @spec standard_provider_delay_ms(profile(), String.t(), String.t(), String.t()) ::
          non_neg_integer()
  def standard_provider_delay_ms(:baseline, _seed, _scenario, _request_key), do: 0

  def standard_provider_delay_ms(:mobile_realistic, seed, scenario, request_key) do
    distributed_delay_ms(seed, scenario, request_key, @mobile_realistic_distribution)
  end

  def standard_provider_delay_ms(:provider_incident, seed, scenario, request_key) do
    distributed_delay_ms(seed, scenario, request_key, @provider_incident_distribution)
  end

  @spec fault_delay_ms(profile(), fault_mode(), String.t(), String.t(), pos_integer()) ::
          pos_integer()
  def fault_delay_ms(:baseline, _mode, _seed, _request_key, fallback_ms), do: max(fallback_ms, 1)

  def fault_delay_ms(:mobile_realistic, :slow, seed, request_key, _fallback_ms) do
    max(
      standard_provider_delay_ms(:mobile_realistic, seed, "provider_fault_slow", request_key),
      1
    )
  end

  def fault_delay_ms(:mobile_realistic, _mode, _seed, _request_key, fallback_ms),
    do: max(fallback_ms, 1)

  def fault_delay_ms(:provider_incident, :slow, seed, request_key, _fallback_ms) do
    max(
      standard_provider_delay_ms(:provider_incident, seed, "provider_fault_slow", request_key),
      1
    )
  end

  def fault_delay_ms(:provider_incident, _mode, seed, request_key, _fallback_ms) do
    max(
      distributed_delay_ms(
        seed,
        "provider_fault_failure",
        request_key,
        [{10_000, {2_000, 3_000}}]
      ),
      1
    )
  end

  @spec request_key(String.t() | nil, map()) :: String.t()
  def request_key(endpoint, params) when is_binary(endpoint) and is_map(params) do
    local_intent_id =
      Map.get(params, "metadata[local_intent_id]") ||
        Map.get(params, "local_intent_id") ||
        Map.get(params, "metadata[payment_intent_key]") ||
        Map.get(params, "metadata[checkout_key]") ||
        Map.get(params, "idempotency_key") ||
        "unknown"

    "#{endpoint}:#{local_intent_id}"
  end

  defp distributed_delay_ms(seed, scenario, request_key, distribution) do
    bucket = deterministic_int(seed, scenario, request_key, "bucket", @bucket_scale)
    {min_ms, max_ms} = distribution_bucket(bucket, distribution)

    min_ms +
      deterministic_int(
        seed,
        scenario,
        request_key,
        "offset",
        max(max_ms - min_ms + 1, 1)
      )
  end

  defp deterministic_int(seed, scenario, request_key, salt, modulus)
       when is_integer(modulus) and modulus > 0 do
    <<value::unsigned-64, _rest::binary>> =
      :crypto.hash(:sha256, [seed, ":", scenario, ":", request_key, ":", salt])

    rem(value, modulus)
  end

  defp distribution_bucket(bucket, distribution) do
    distribution
    |> Enum.find(fn {threshold, _range} -> bucket < threshold end)
    |> case do
      {_threshold, range} -> range
      nil -> distribution |> List.last() |> elem(1)
    end
  end
end
