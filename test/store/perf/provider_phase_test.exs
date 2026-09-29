defmodule Store.PerformanceSmoke.ProviderPhaseTest do
  use ExUnit.Case, async: false

  alias Store.PerformanceSmoke.ProviderPhase

  @event [:store, :checkout, :provider_setup_task]

  test "provider setup telemetry moves observer phase through the provider wait" do
    {:ok, handler_id} = ProviderPhase.start_tracking()

    try do
      assert ProviderPhase.current() == :pre_provider

      :telemetry.execute(@event, %{}, %{result: :started})
      assert ProviderPhase.current() == :provider_wait

      :telemetry.execute(@event, %{}, %{result: :ok})
      assert ProviderPhase.current() == :post_provider
    after
      ProviderPhase.stop_tracking(handler_id)
    end

    assert ProviderPhase.current() == :untracked
  end
end
