defmodule Store.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Store.Catalog.ProductListCache
  alias Store.Payments.ProviderConfig
  alias Store.Shipping.QuoteCache
  alias Store.Support.EtsTableOwner
  alias Store.Support.RateLimit.RedixClient
  alias Store.Support.Redis
  alias Store.Support.Telemetry.RedisAggregates

  @impl true
  def start(_type, _args) do
    children =
      [
        StoreWeb.Telemetry,
        Store.Repo,
        Store.DirectRepo,
        {Task.Supervisor, name: Store.Payments.ProviderTaskSupervisor},
        payment_finch_child_spec(),
        {Oban, Application.fetch_env!(:store, Oban)},
        {AshAuthentication.Supervisor, otp_app: :store},
        {DNSCluster, query: Application.get_env(:store, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Store.PubSub},
        Store.Entitlements.Cache,
        {EtsTableOwner, table: :store_catalog_availability_cache},
        {EtsTableOwner, table: :store_catalog_stock_fast_path},
        {EtsTableOwner, table: :store_rate_limit},
        ProductListCache,
        QuoteCache,
        maybe_redis_child_spec(),
        RedisAggregates,
        # Start a worker by calling: Store.Worker.start_link(arg)
        # {Store.Worker, arg},
        # Start to serve requests, typically the last entry
        StoreWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Store.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_redis_child_spec do
    rate_limit_config = Application.get_env(:store, :rate_limit, [])

    redis_client = Keyword.get(rate_limit_config, :redis_client)
    redis_config = Keyword.get(rate_limit_config, :redis, [])

    if redis_client == RedixClient and redis_config != [] do
      redis_config
      |> Keyword.put_new(:name, Redis.connection_name())
      |> Keyword.put_new(:sync_connect, true)
      |> then(&{Redix, &1})
    end
  end

  defp payment_finch_child_spec do
    Supervisor.child_spec(
      {Finch, name: ProviderConfig.finch_name(), pools: ProviderConfig.finch_pools()},
      id: ProviderConfig.finch_name()
    )
  end
end
