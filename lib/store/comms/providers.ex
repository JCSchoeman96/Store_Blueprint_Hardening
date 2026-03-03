defmodule Store.Comms.Providers do
  @moduledoc """
  Resolver and wrapper for comms delivery adapters.
  """

  alias Store.Comms.Providers.{ReqPostmarkAdapter, SwooshAdapter}

  @type provider :: :swoosh | :req_postmark | String.t() | atom()

  @spec default_provider() :: :swoosh | :req_postmark
  def default_provider do
    Application.get_env(:store, :comms, [])
    |> Keyword.get(:default_provider, :swoosh)
    |> normalize_provider!()
  end

  @spec normalize_provider(provider()) :: {:ok, :swoosh | :req_postmark} | {:error, term()}
  def normalize_provider(provider) do
    {:ok, normalize_provider!(provider)}
  rescue
    _ -> {:error, :invalid_provider}
  end

  @spec adapter(provider()) :: module()
  def adapter(provider) do
    case normalize_provider!(provider) do
      :swoosh -> SwooshAdapter
      :req_postmark -> ReqPostmarkAdapter
    end
  end

  @spec deliver_email(provider(), map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, :transient, term()} | {:error, :permanent, term()}
  def deliver_email(provider, payload, opts \\ []) when is_map(payload) and is_list(opts) do
    adapter(provider).deliver_email(payload, opts)
  end

  defp normalize_provider!(provider) when provider in [:swoosh, "swoosh", "SWOOSH"], do: :swoosh

  defp normalize_provider!(provider)
       when provider in [:req_postmark, "req_postmark", "REQ_POSTMARK"] do
    :req_postmark
  end

  defp normalize_provider!(_provider), do: raise(ArgumentError, "invalid provider")
end
