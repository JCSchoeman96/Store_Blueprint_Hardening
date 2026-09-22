defmodule Store.Payments.ProviderConfig do
  @moduledoc false

  alias Store.Support.Errors.Error

  @default_api_base_url "https://api.stripe.com"
  @default_task_timeout_ms 4_000
  @default_http_pool_size 400
  @default_http_receive_timeout_ms 6_000
  @default_http_pool_timeout_ms 5_000

  @spec finch_name() :: module()
  def finch_name, do: Store.Payments.Finch

  @spec stripe_api_base_url() :: String.t()
  def stripe_api_base_url do
    stripe_config()
    |> Keyword.get(:api_base_url, @default_api_base_url)
  end

  @spec task_timeout_ms() :: pos_integer()
  def task_timeout_ms do
    stripe_config()
    |> Keyword.get(:payment_provider_task_timeout_ms, @default_task_timeout_ms)
  end

  @spec http_pool_size() :: pos_integer()
  def http_pool_size do
    stripe_config()
    |> Keyword.get(:payment_http_pool_size, @default_http_pool_size)
  end

  @spec http_receive_timeout_ms() :: pos_integer()
  def http_receive_timeout_ms do
    stripe_config()
    |> Keyword.get(:payment_http_receive_timeout_ms, @default_http_receive_timeout_ms)
  end

  @spec http_pool_timeout_ms() :: pos_integer()
  def http_pool_timeout_ms do
    stripe_config()
    |> Keyword.get(:payment_http_pool_timeout_ms, @default_http_pool_timeout_ms)
  end

  @spec finch_pools() :: map()
  def finch_pools do
    %{
      stripe_api_base_url() => [size: http_pool_size()]
    }
  end

  @spec request_options() :: keyword()
  def request_options do
    opts =
      stripe_config()
      |> Keyword.get(:request_options, [])
      |> Keyword.put_new(:receive_timeout, http_receive_timeout_ms())

    opts
    |> Keyword.delete(:pool_timeout)
    |> put_finch_request_options()
    |> reject_conflicting_transport_options!()
  end

  defp put_finch_request_options(opts) do
    pool_timeout = http_pool_timeout_ms()

    case Keyword.get(opts, :finch) do
      nil ->
        Keyword.put(opts, :finch, name: finch_name(), pool_timeout: pool_timeout)

      name when is_atom(name) ->
        Keyword.put(opts, :finch, name: name, pool_timeout: pool_timeout)

      finch_opts when is_list(finch_opts) ->
        Keyword.put(opts, :finch, Keyword.put_new(finch_opts, :pool_timeout, pool_timeout))
    end
  end

  defp reject_conflicting_transport_options!(opts) do
    if Keyword.has_key?(opts, :connect_options) do
      raise ArgumentError, "cannot set both :finch and :connect_options"
    end

    opts
  end

  @spec validate_timeout_hierarchy() :: :ok | {:error, Error.t()}
  def validate_timeout_hierarchy do
    task_timeout_ms = task_timeout_ms()
    receive_timeout_ms = http_receive_timeout_ms()
    pool_timeout_ms = http_pool_timeout_ms()

    cond do
      receive_timeout_ms <= task_timeout_ms ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_DOWN",
           "stripe receive timeout must exceed provider task timeout",
           %{
             task_timeout_ms: task_timeout_ms,
             receive_timeout_ms: receive_timeout_ms
           }
         )}

      pool_timeout_ms <= task_timeout_ms ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_DOWN",
           "stripe pool timeout must exceed provider task timeout",
           %{
             task_timeout_ms: task_timeout_ms,
             pool_timeout_ms: pool_timeout_ms
           }
         )}

      true ->
        :ok
    end
  end

  defp payments_config do
    Application.get_env(:store, :payments, [])
  end

  defp stripe_config do
    payments_config()
    |> Keyword.get(:stripe, [])
  end
end
