defmodule Store.Support.Redis do
  @moduledoc """
  Shared Redis helpers for warm caches and high-velocity aggregate storage.
  """

  alias Store.Support.RateLimit.RedixClient

  @default_scan_count 100

  @spec command([String.t() | binary()]) :: {:ok, term()} | {:error, term()}
  def command(args) when is_list(args) do
    Redix.command(connection_name(), args)
  end

  @spec pipeline([[String.t() | binary()]]) :: {:ok, [term()]} | {:error, term()}
  def pipeline(commands) when is_list(commands) do
    Redix.pipeline(connection_name(), commands)
  end

  @spec ping() :: :ok | {:error, term()}
  def ping, do: RedixClient.ping()

  @spec flush_db() :: :ok | {:error, term()}
  def flush_db, do: RedixClient.flush_db()

  @spec key(String.t()) :: String.t()
  def key(relative_key) when is_binary(relative_key) do
    "#{key_prefix()}:#{relative_key}"
  end

  @spec term_get(String.t()) :: {:ok, :miss | {:hit, term()}} | {:error, term()}
  def term_get(relative_key) when is_binary(relative_key) do
    case command(["GET", key(relative_key)]) do
      {:ok, nil} ->
        {:ok, :miss}

      {:ok, value} when is_binary(value) ->
        {:ok, {:hit, :erlang.binary_to_term(value, [:safe])}}

      {:ok, unexpected} ->
        {:error, {:unexpected_redis_reply, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec term_put(String.t(), term(), pos_integer()) :: :ok | {:error, term()}
  def term_put(relative_key, value, ttl_seconds)
      when is_binary(relative_key) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    encoded = :erlang.term_to_binary(value, [:compressed])

    case command(["SET", key(relative_key), encoded, "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, "OK"} -> :ok
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  def term_put(_relative_key, _value, _ttl_seconds), do: {:error, :invalid_term_put_args}

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(relative_key) when is_binary(relative_key) do
    case command(["DEL", key(relative_key)]) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_prefix(String.t()) :: :ok | {:error, term()}
  def delete_prefix(relative_prefix) when is_binary(relative_prefix) do
    do_delete_prefix(key(relative_prefix) <> "*", "0")
  end

  @spec hash_incr_by(String.t(), String.t(), integer(), pos_integer()) :: :ok | {:error, term()}
  def hash_incr_by(relative_key, field, increment, ttl_seconds)
      when is_binary(relative_key) and is_binary(field) and is_integer(increment) and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    case pipeline([
           ["HINCRBY", key(relative_key), field, Integer.to_string(increment)],
           ["EXPIRE", key(relative_key), Integer.to_string(ttl_seconds)]
         ]) do
      {:ok, [_count, _expire]} -> :ok
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  def hash_incr_by(_relative_key, _field, _increment, _ttl_seconds),
    do: {:error, :invalid_hash_incr_by_args}

  @spec hash_get_all(String.t()) :: {:ok, map()} | {:error, term()}
  def hash_get_all(relative_key) when is_binary(relative_key) do
    case command(["HGETALL", key(relative_key)]) do
      {:ok, values} when is_list(values) ->
        {:ok,
         values
         |> Enum.chunk_every(2)
         |> Map.new(fn [field, value] -> {field, value} end)}

      {:ok, unexpected} ->
        {:error, {:unexpected_redis_reply, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec zadd_with_ttl(String.t(), integer(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def zadd_with_ttl(relative_key, score, member, ttl_seconds)
      when is_binary(relative_key) and is_integer(score) and is_binary(member) and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    case pipeline([
           ["ZADD", key(relative_key), Integer.to_string(score), member],
           ["EXPIRE", key(relative_key), Integer.to_string(ttl_seconds)]
         ]) do
      {:ok, [_added, _expire]} -> :ok
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  def zadd_with_ttl(_relative_key, _score, _member, _ttl_seconds),
    do: {:error, :invalid_zadd_args}

  @spec zrem(String.t(), String.t()) :: :ok | {:error, term()}
  def zrem(relative_key, member) when is_binary(relative_key) and is_binary(member) do
    case command(["ZREM", key(relative_key), member]) do
      {:ok, _removed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec zmembers(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def zmembers(relative_key) when is_binary(relative_key) do
    case command(["ZRANGE", key(relative_key), "0", "-1"]) do
      {:ok, members} when is_list(members) -> {:ok, members}
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec pfadd(String.t(), [String.t()], pos_integer()) :: :ok | {:error, term()}
  def pfadd(relative_key, members, ttl_seconds)
      when is_binary(relative_key) and is_list(members) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    normalized_members =
      members
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if normalized_members == [] do
      :ok
    else
      case pipeline([
             ["PFADD", key(relative_key) | normalized_members],
             ["EXPIRE", key(relative_key), Integer.to_string(ttl_seconds)]
           ]) do
        {:ok, [_added, _expire]} -> :ok
        {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def pfadd(_relative_key, _members, _ttl_seconds), do: {:error, :invalid_pfadd_args}

  @spec pfcount(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pfcount(relative_key) when is_binary(relative_key) do
    case command(["PFCOUNT", key(relative_key)]) do
      {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, unexpected} -> {:error, {:unexpected_redis_reply, unexpected}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec window_member(String.t(), integer()) :: String.t()
  def window_member(prefix, unique_integer)
      when is_binary(prefix) and is_integer(unique_integer) do
    "#{prefix}:#{unique_integer}"
  end

  @spec connection_name() :: atom()
  def connection_name, do: RedixClient.connection_name()

  @spec key_prefix() :: String.t()
  def key_prefix do
    Application.get_env(:store, :rate_limit, [])
    |> Keyword.get(:redis_key_prefix, "store")
  end

  defp do_delete_prefix(match, cursor) do
    case command([
           "SCAN",
           cursor,
           "MATCH",
           match,
           "COUNT",
           Integer.to_string(@default_scan_count)
         ]) do
      {:ok, [next_cursor, keys]} when is_binary(next_cursor) and is_list(keys) ->
        delete_keys(keys)

        if next_cursor == "0" do
          :ok
        else
          do_delete_prefix(match, next_cursor)
        end

      {:ok, unexpected} ->
        {:error, {:unexpected_redis_reply, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_keys([]), do: :ok

  defp delete_keys(keys) do
    case command(["DEL" | keys]) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
