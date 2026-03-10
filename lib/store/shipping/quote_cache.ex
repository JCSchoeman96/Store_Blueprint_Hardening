defmodule Store.Shipping.QuoteCache do
  @moduledoc """
  Cluster-safe shipping quote cache with Cachex hot storage, Redis warm storage,
  and PubSub invalidation fanout.
  """

  import Cachex.Spec

  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Support.Governance.Idempotency
  alias Store.Support.Redis

  @cache_ttl_ms :timer.seconds(45)
  @warm_ttl_seconds 900
  @topic "store:shipping:quote_cache"

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {Supervisor, :start_link, [children(), [strategy: :one_for_one, name: supervisor_name()]]}
    }
  end

  @spec fetch(QuoteRequest.t(), (-> [term()])) ::
          {:ok, [term()], %{cache: String.t(), layer: String.t(), request_key: String.t()}}
  def fetch(%QuoteRequest{} = request, fallback) when is_function(fallback, 0) do
    key = request_key(request)

    case Cachex.get(__MODULE__, key) do
      {:ok, {value, _source_layer}} ->
        {:ok, value, %{cache: "hit", layer: "hot", request_key: key}}

      {:ok, nil} ->
        fetch_miss(key, fallback)

      {:error, _reason} ->
        value = fallback.()
        {:ok, value, %{cache: "miss", layer: "cold", request_key: key}}
    end
  end

  @spec invalidate_all_local() :: :ok
  def invalidate_all_local do
    case Cachex.clear(__MODULE__) do
      {:ok, _count} -> :ok
      _ -> :ok
    end
  end

  @spec invalidate_all(String.t() | nil) :: :ok
  def invalidate_all(reason \\ nil) do
    _ = invalidate_all_local()
    _ = Redis.delete_prefix(redis_prefix())

    Phoenix.PubSub.broadcast(
      Store.PubSub,
      @topic,
      {:invalidate_all, __MODULE__, reason, DateTime.utc_now() |> DateTime.truncate(:microsecond)}
    )

    :ok
  end

  @spec request_key(QuoteRequest.t()) :: String.t()
  def request_key(%QuoteRequest{} = request) do
    payload = %{
      country: request.destination_country_code,
      region: request.destination_region_code,
      postal: request.destination_postal_code,
      currency: request.currency_code,
      weight: request.shipping_weight_grams
    }

    "v1:" <> Idempotency.payload_hash(payload)
  end

  defp children do
    [
      %{
        id: Module.concat(__MODULE__, Cachex),
        start:
          {Cachex, :start_link,
           [
             __MODULE__,
             [
               expiration:
                 expiration(
                   default: @cache_ttl_ms,
                   interval: :timer.seconds(15),
                   lazy: true
                 )
             ]
           ]}
      },
      %{
        id: Module.concat(__MODULE__, Subscriber),
        start: {Task, :start_link, [fn -> subscriber_loop() end]}
      }
    ]
  end

  defp supervisor_name, do: Module.concat(__MODULE__, Supervisor)

  defp fetch_miss(key, fallback) do
    case Cachex.fetch(__MODULE__, key, fn _key -> {:commit, load_value(key, fallback)} end, []) do
      {:commit, {value, layer}} ->
        {:ok, value, %{cache: "miss", layer: Atom.to_string(layer), request_key: key}}

      {:ok, {value, _layer}} ->
        {:ok, value, %{cache: "hit", layer: "hot", request_key: key}}

      {:error, _reason} ->
        value = fallback.()
        {:ok, value, %{cache: "miss", layer: "cold", request_key: key}}
    end
  end

  defp load_value(key, fallback) do
    case Redis.term_get(redis_key(key)) do
      {:ok, {:hit, value}} ->
        {value, :warm}

      _ ->
        value = fallback.()
        _ = Redis.term_put(redis_key(key), value, @warm_ttl_seconds)
        {value, :cold}
    end
  end

  defp redis_prefix, do: "cache:shipping:quote"
  defp redis_key(key), do: "#{redis_prefix()}:#{key}"

  defp subscriber_loop do
    Phoenix.PubSub.subscribe(Store.PubSub, @topic)

    receive do
      {:invalidate_all, __MODULE__, _reason, _occurred_at} ->
        _ = invalidate_all_local()
        subscriber_loop()
    end
  end
end
