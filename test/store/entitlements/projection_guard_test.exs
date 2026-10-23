defmodule Store.Entitlements.ProjectionGuardTransactionTest do
  use Store.DataCase, async: false

  alias Store.Entitlements.Cache
  alias Store.Entitlements.Facade
  alias Store.Repo
  alias Store.Support.Errors.Error

  test "refuses projection invalidation inside a transaction without changing cache or PubSub" do
    user_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    reason = "task5_projection_guard"

    Enum.each(user_ids, fn user_id ->
      cache_value = {:cached_entitlements, user_id}
      assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), cache_value)
      Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))
    end)

    cache_before = cache_values(user_ids)

    assert {:ok, {result, cache_after}} =
             Repo.transaction(fn ->
               assert Repo.in_transaction?()

               result =
                 Facade.invalidate_subscription_source_users_after_commit_for_system(
                   user_ids,
                   reason
                 )

               {result, cache_values(user_ids)}
             end)

    assert {:error, %Error{code: "VALIDATION_ERROR"}} = result
    assert cache_before == Enum.map(user_ids, &{:ok, {:cached_entitlements, &1}})
    assert cache_after == cache_before

    Enum.each(user_ids, fn user_id ->
      refute_receive {:entitlements_invalidated, ^user_id, ^reason, _occurred_at}
      assert {:ok, {:cached_entitlements, ^user_id}} = Cachex.get(Cache, Cache.cache_key(user_id))
      assert :ok = Cache.invalidate_local(user_id)
    end)
  end

  defp cache_values(user_ids) do
    Enum.map(user_ids, &Cachex.get(Cache, Cache.cache_key(&1)))
  end
end

defmodule Store.Entitlements.ProjectionGuardOrderingTest do
  use ExUnit.Case, async: false

  alias Store.Entitlements.Cache
  alias Store.Entitlements.Facade
  alias Store.Repo

  test "invalidates each user's cache before that user's PubSub event" do
    user_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    reason = "task5_projection_order"

    refute Repo.in_transaction?()

    Enum.each(user_ids, fn user_id ->
      cache_value = {:cached_entitlements, user_id}
      assert {:ok, true} = Cachex.put(Cache, Cache.cache_key(user_id), cache_value)
      Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(user_id))
    end)

    task =
      Task.async(fn ->
        Facade.invalidate_subscription_source_users_after_commit_for_system(user_ids, reason)
      end)

    received_user_ids =
      for _index <- 1..2 do
        assert_receive {:entitlements_invalidated, user_id, ^reason, _occurred_at}, 1_000
        assert user_id in user_ids
        assert {:ok, nil} = Cachex.get(Cache, Cache.cache_key(user_id))
        user_id
      end

    assert :ok = Task.await(task)
    assert MapSet.new(received_user_ids) == MapSet.new(user_ids)

    Enum.each(user_ids, fn user_id ->
      refute_receive {:entitlements_invalidated, ^user_id, ^reason, _occurred_at}
    end)
  end
end
