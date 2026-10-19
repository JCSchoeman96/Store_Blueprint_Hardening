defmodule Store.Entitlements.CacheProjectionRepairTest do
  use ExUnit.Case, async: false

  alias Store.Entitlements.Cache

  test "cache invalidation failure is surfaced and suppresses PubSub broadcast" do
    user_id = "01a1504e-0000-7000-8000-000000000001"
    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))

    assert :ok = Supervisor.terminate_child(Store.Supervisor, Cache)

    try do
      assert {:error, %{user_id: ^user_id, step: :cache_invalidation, reason: _reason}} =
               Cache.invalidate_and_broadcast_post_commit(user_id, "jc239_projection_test")

      refute_receive {:entitlements_invalidated, ^user_id, _, _}
    after
      assert {:ok, _pid} = Supervisor.restart_child(Store.Supervisor, Cache)
    end
  end

  test "PubSub failure is surfaced after cache invalidation succeeds" do
    user_id = "01a1504e-0000-7000-8000-000000000002"

    assert {:error, %{user_id: ^user_id, step: :pubsub_broadcast, reason: _reason}} =
             Cache.invalidate_and_broadcast_post_commit(
               user_id,
               "jc239_projection_test",
               pubsub_server: :jc239_missing_pubsub
             )
  end
end
