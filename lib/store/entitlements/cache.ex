defmodule Store.Entitlements.Cache do
  @moduledoc """
  Cachex-backed hot cache and PubSub fanout for per-user entitlement sets.
  """

  import Cachex.Spec

  @cache_ttl_ms :timer.seconds(60)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {Cachex, :start_link,
         [
           __MODULE__,
           [
             expiration:
               expiration(
                 default: @cache_ttl_ms,
                 interval: :timer.seconds(30),
                 lazy: true
               )
           ]
         ]}
    }
  end

  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @cache_ttl_ms

  @spec cache_key(String.t()) :: String.t()
  def cache_key(user_id) when is_binary(user_id), do: "user:#{user_id}"

  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: "store:entitlements:#{user_id}"

  @spec fetch(String.t(), (-> {:commit, term()} | {:ignore, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(user_id, fallback) when is_binary(user_id) and is_function(fallback, 0) do
    case Cachex.fetch(__MODULE__, cache_key(user_id), fn _key -> fallback.() end, []) do
      {:commit, value} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      {:ignore, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec invalidate_local(String.t()) :: :ok | {:error, term()}
  def invalidate_local(user_id) when is_binary(user_id) do
    case Cachex.del(__MODULE__, cache_key(user_id)) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec broadcast_invalidation(String.t(), String.t() | nil, DateTime.t()) :: :ok
  def broadcast_invalidation(user_id, reason, %DateTime{} = occurred_at)
      when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Store.PubSub,
      topic(user_id),
      {:entitlements_invalidated, user_id, reason, occurred_at}
    )
  end

  @spec invalidate_and_broadcast_post_commit(String.t(), String.t() | nil, keyword()) :: :ok
  def invalidate_and_broadcast_post_commit(user_id, reason, opts \\ [])
      when is_binary(user_id) and is_list(opts) do
    occurred_at =
      Keyword.get(opts, :occurred_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    _ = invalidate_local(user_id)
    broadcast_invalidation(user_id, reason, occurred_at)
    :ok
  end
end
