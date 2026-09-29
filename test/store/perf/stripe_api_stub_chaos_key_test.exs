defmodule Store.Perf.StripeAPIStubChaosKeyTest do
  use ExUnit.Case, async: true

  require Logger

  alias Store.Payments.ProviderTask
  alias Store.Perf.ChaosProfile
  alias Store.TestSupport.StripeAPIStub

  defp volatile_params(local_intent_id) do
    %{
      "metadata[local_intent_id]" => local_intent_id,
      "amount" => "1000",
      "currency" => "usd"
    }
  end

  defp fresh_uuid_like do
    Ash.UUIDv7.generate()
  end

  describe "ProviderTask process boundary" do
    test "logical chaos key reaches the provider child spawned by ProviderTask.execute/2" do
      params = volatile_params(fresh_uuid_like())
      fallback_key = ChaosProfile.request_key("payment_intents", params)

      assert {:ok, %{observed_key: observed_key}} =
               StripeAPIStub.with_chaos_request_key("provider_fault_slow:7", fn ->
                 ProviderTask.execute(
                   fn ->
                     {:ok,
                      %{
                        observed_key: StripeAPIStub.chaos_request_key("payment_intents", params)
                      }}
                   end,
                   provider: :stripe,
                   timeout_ms: 5_000
                 )
               end)

      assert observed_key == "payment_intents:provider_fault_slow:7"
      refute observed_key == fallback_key
    end

    test "concurrent ProviderTask executions preserve independent logical chaos keys" do
      parent = self()
      ref = make_ref()

      for {logical_key, label} <- [
            {"provider_fault_slow:1", :one},
            {"provider_fault_slow:2", :two}
          ] do
        Task.start(fn ->
          result =
            StripeAPIStub.with_chaos_request_key(logical_key, fn ->
              ProviderTask.execute(
                fn ->
                  params = volatile_params(fresh_uuid_like())

                  {:ok,
                   %{
                     label: label,
                     key: StripeAPIStub.chaos_request_key("payment_intents", params)
                   }}
                end,
                provider: :stripe,
                timeout_ms: 5_000
              )
            end)

          send(parent, {ref, result})
        end)
      end

      assert_receive {^ref, {:ok, %{label: :one, key: "payment_intents:provider_fault_slow:1"}}},
                     5_000

      assert_receive {^ref, {:ok, %{label: :two, key: "payment_intents:provider_fault_slow:2"}}},
                     5_000

      refute_received {^ref, {:ok, %{label: :one, key: "payment_intents:provider_fault_slow:2"}}}
      refute_received {^ref, {:ok, %{label: :two, key: "payment_intents:provider_fault_slow:1"}}}
    end
  end

  describe "with_chaos_request_key/2 request key resolution" do
    test "stable logical key ignores volatile metadata local_intent_id values" do
      endpoint = "payment_intents"
      params_a = volatile_params(fresh_uuid_like())
      params_b = volatile_params(fresh_uuid_like())

      refute StripeAPIStub.chaos_request_key(endpoint, params_a) ==
               StripeAPIStub.chaos_request_key(endpoint, params_b)

      key_a =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:7", fn ->
          StripeAPIStub.chaos_request_key(endpoint, params_a)
        end)

      key_b =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:7", fn ->
          StripeAPIStub.chaos_request_key(endpoint, params_b)
        end)

      assert key_a == key_b
      assert key_a == "payment_intents:provider_fault_slow:7"
    end

    test "different logical request keys remain distinct" do
      endpoint = "payment_intents"
      params = volatile_params(fresh_uuid_like())

      key_one =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:1", fn ->
          StripeAPIStub.chaos_request_key(endpoint, params)
        end)

      key_two =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:2", fn ->
          StripeAPIStub.chaos_request_key(endpoint, params)
        end)

      refute key_one == key_two
    end
  end

  describe "delay vector determinism" do
    test "same logical ordinals produce identical delay vectors across volatile id passes" do
      profile = :mobile_realistic
      seed = "ci-mobile-realistic"
      endpoint = "payment_intents"
      ordinals = 1..50

      delay_vector = fn ->
        Enum.map(ordinals, fn ordinal ->
          logical_key = "provider_fault_slow:#{ordinal}"
          params = volatile_params(fresh_uuid_like())

          request_key =
            StripeAPIStub.with_chaos_request_key(logical_key, fn ->
              StripeAPIStub.chaos_request_key(endpoint, params)
            end)

          ChaosProfile.standard_provider_delay_ms(profile, seed, endpoint, request_key)
        end)
      end

      vector_a = delay_vector.()
      vector_b = delay_vector.()

      assert vector_a == vector_b
      assert Enum.uniq(vector_a) |> length() > 8
    end
  end

  describe "process isolation" do
    test "concurrent tasks do not share logical chaos keys" do
      parent = self()

      tasks =
        [
          {"provider_fault_slow:alpha", :alpha},
          {"provider_fault_slow:beta", :beta}
        ]
        |> Task.async_stream(
          fn {logical_key, label} ->
            StripeAPIStub.with_chaos_request_key(logical_key, fn ->
              key =
                StripeAPIStub.chaos_request_key("payment_intents", volatile_params("volatile"))

              send(parent, {label, key})
              key
            end)
          end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.to_list()

      assert length(tasks) == 2

      assert_receive {:alpha, "payment_intents:provider_fault_slow:alpha"}, 500
      assert_receive {:beta, "payment_intents:provider_fault_slow:beta"}, 500

      refute StripeAPIStub.chaos_request_key(
               "payment_intents",
               volatile_params("after")
             ) == "payment_intents:provider_fault_slow:alpha"
    end
  end

  describe "with_chaos_request_key/2 cleanup" do
    test "restores previous key after normal return" do
      params = volatile_params(fresh_uuid_like())
      baseline = StripeAPIStub.chaos_request_key("payment_intents", params)

      result =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:1", fn ->
          StripeAPIStub.chaos_request_key("payment_intents", params)
        end)

      assert result == "payment_intents:provider_fault_slow:1"
      assert StripeAPIStub.chaos_request_key("payment_intents", params) == baseline
    end

    test "restores previous key after exception" do
      params = volatile_params(fresh_uuid_like())
      baseline = StripeAPIStub.chaos_request_key("payment_intents", params)

      assert_raise RuntimeError, "boom", fn ->
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:9", fn ->
          raise "boom"
        end)
      end

      assert StripeAPIStub.chaos_request_key("payment_intents", params) == baseline
    end

    test "nested overrides restore parent value" do
      params = volatile_params(fresh_uuid_like())

      outer =
        StripeAPIStub.with_chaos_request_key("provider_fault_slow:outer", fn ->
          inner =
            StripeAPIStub.with_chaos_request_key("provider_fault_slow:inner", fn ->
              StripeAPIStub.chaos_request_key("payment_intents", params)
            end)

          {inner, StripeAPIStub.chaos_request_key("payment_intents", params)}
        end)

      assert outer ==
               {"payment_intents:provider_fault_slow:inner",
                "payment_intents:provider_fault_slow:outer"}

      refute StripeAPIStub.chaos_request_key("payment_intents", params) ==
               "payment_intents:provider_fault_slow:inner"
    end
  end
end
