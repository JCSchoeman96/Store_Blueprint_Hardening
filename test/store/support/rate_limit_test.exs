defmodule Store.Support.RateLimitTest do
  use ExUnit.Case, async: false

  alias Store.Support.RateLimit
  alias Store.Support.RateLimit.EtsBackend
  alias Store.Support.RateLimit.RedisBackend

  setup do
    previous = Application.get_env(:store, :rate_limit, [])
    Application.put_env(:store, :rate_limit, Keyword.put(previous, :backend, EtsBackend))

    case :ets.whereis(:store_rate_limit) do
      :undefined -> :ok
      table -> :ets.delete(table)
    end

    on_exit(fn ->
      Application.put_env(:store, :rate_limit, previous)

      case :ets.whereis(:store_rate_limit) do
        :undefined -> :ok
        table -> :ets.delete(table)
      end
    end)

    :ok
  end

  test "ets backend allows within limit then denies in same window" do
    key = "grant:test:#{System.unique_integer([:positive])}"

    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, key, 2, 300)
    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, key, 2, 300)
    assert {:ok, :deny} = RateLimit.allow?(:digital_signed_url, key, 2, 300)
  end

  test "check returns count metadata for thresholded gates" do
    key = "gate:test:#{System.unique_integer([:positive])}"

    assert {:ok, %{decision: :allow, count: 1, limit: 2, window_seconds: 60}} =
             RateLimit.check(:waiting_room_http, key, 2, 60)

    assert {:ok, %{decision: :allow, count: 2}} =
             RateLimit.check(:waiting_room_http, key, 2, 60)

    assert {:ok, %{decision: :deny, count: 3}} =
             RateLimit.check(:waiting_room_http, key, 2, 60)
  end

  test "ets backend isolates counters by key" do
    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, "grant-a", 1, 300)
    assert {:ok, :deny} = RateLimit.allow?(:digital_signed_url, "grant-a", 1, 300)
    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, "grant-b", 1, 300)
  end

  test "redis seam returns not configured when redis client is absent" do
    Application.put_env(:store, :rate_limit, backend: RedisBackend)

    assert {:error, :redis_client_not_configured} =
             RateLimit.allow?(:digital_signed_url, "a", 1, 60)
  end

  test "redis seam delegates to configured client" do
    Application.put_env(:store, :rate_limit,
      backend: RedisBackend,
      redis_client: __MODULE__.FakeRedisClient
    )

    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, "k1", 2, 60)
    assert {:ok, :allow} = RateLimit.allow?(:digital_signed_url, "k1", 2, 60)
    assert {:ok, :deny} = RateLimit.allow?(:digital_signed_url, "k1", 2, 60)
  end

  defmodule FakeRedisClient do
    @moduledoc false

    def incr_with_ttl(key, _ttl_seconds) when is_binary(key) do
      table = ensure_table()
      count = :ets.update_counter(table, key, {2, 1}, {key, 0})
      {:ok, count}
    end

    defp ensure_table do
      case :ets.whereis(:store_rate_limit_redis_fake) do
        :undefined ->
          :ets.new(:store_rate_limit_redis_fake, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        table ->
          table
      end
    end
  end
end
