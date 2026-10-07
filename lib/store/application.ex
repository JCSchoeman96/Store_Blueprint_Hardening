defmodule Store.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Store.Catalog.ProductListCache
  alias Store.Orders.InventoryAdmission.Config, as: InventoryAdmissionConfig
  alias Store.Payments.ProviderConfig
  alias Store.Shipping.QuoteCache
  alias Store.Support.EtsTableOwner
  alias Store.Support.RateLimit.RedixClient
  alias Store.Support.Redis
  alias Store.Support.Telemetry.RedisAggregates

  @impl true
  def start(_type, _args) do
    start_with_inventory_admission_config(InventoryAdmissionConfig.load())
  end

  @doc false
  def validate_inventory_admission_startup(mode, redis_ping \\ &Redis.ping/0)

  def validate_inventory_admission_startup(mode, redis_ping) when is_function(redis_ping, 0) do
    case InventoryAdmissionConfig.load() do
      {:ok, %InventoryAdmissionConfig{mode: :disabled}} when mode == :disabled ->
        :ok

      {:ok, %InventoryAdmissionConfig{mode: :enforced}} when mode == :enforced ->
        validate_redis_readiness(redis_ping)

      _result ->
        {:error, :invalid_enforced_config}
    end
  end

  def validate_inventory_admission_startup(_mode, _redis_ping),
    do: {:error, :invalid_enforced_config}

  @doc false
  def start_endpoint(mode) do
    with :ok <- validate_inventory_admission_startup(mode) do
      StoreWeb.Endpoint.start_link([])
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp start_with_inventory_admission_config({:ok, config}) do
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
        endpoint_child_spec(config.mode)
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Store.Supervisor]
    start_supervisor(children, opts, config.mode)
  end

  defp start_with_inventory_admission_config({:error, _reason}),
    do: {:error, :invalid_enforced_config}

  defp start_supervisor(children, opts, :enforced) do
    case Supervisor.start_link(children, opts) do
      {:error, {:shutdown, {:failed_to_start_child, Redix, _reason}}} ->
        {:error, :redis_unavailable}

      {:error, {:failed_to_start_child, Redix, _reason}} ->
        {:error, :redis_unavailable}

      result ->
        result
    end
  end

  defp start_supervisor(children, opts, _mode), do: Supervisor.start_link(children, opts)

  defp endpoint_child_spec(mode) do
    Supervisor.child_spec({StoreWeb.Endpoint, []},
      start: {__MODULE__, :start_endpoint, [mode]}
    )
  end

  defp validate_redis_readiness(redis_ping) do
    case redis_ping.() do
      :ok -> :ok
      _result -> {:error, :redis_unavailable}
    end
  rescue
    _error -> {:error, :redis_unavailable}
  catch
    _kind, _reason -> {:error, :redis_unavailable}
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
