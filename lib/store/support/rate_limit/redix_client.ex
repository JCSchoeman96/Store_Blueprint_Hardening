defmodule Store.Support.RateLimit.RedixClient do
  @moduledoc """
  Redix adapter for `Store.Support.RateLimit.RedisBackend`.
  """

  @default_connection_name :store_rate_limit_redis
  @incr_with_ttl_script """
  local current = redis.call("INCR", KEYS[1])
  if current == 1 then
    redis.call("EXPIRE", KEYS[1], ARGV[1])
  end
  return current
  """

  @spec incr_with_ttl(String.t(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def incr_with_ttl(key, ttl_seconds)
      when is_binary(key) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    case Redix.command(connection_name(), [
           "EVAL",
           @incr_with_ttl_script,
           "1",
           key,
           Integer.to_string(ttl_seconds)
         ]) do
      {:ok, count} when is_integer(count) and count > 0 ->
        {:ok, count}

      {:ok, unexpected} ->
        {:error, {:unexpected_redis_reply, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def incr_with_ttl(_key, _ttl_seconds), do: {:error, :invalid_redis_counter_args}

  @spec flush_db() :: :ok | {:error, term()}
  def flush_db do
    case Redix.command(connection_name(), ["FLUSHDB"]) do
      {:ok, "OK"} -> :ok
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec connection_name() :: atom()
  def connection_name do
    Application.get_env(:store, :rate_limit, [])
    |> Keyword.get(:redis_name, @default_connection_name)
  end
end
