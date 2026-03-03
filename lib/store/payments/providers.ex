defmodule Store.Payments.Providers do
  @moduledoc """
  Provider adapter resolver and boundary wrapper.
  """

  alias Store.Payments.Providers.Stripe

  @type provider :: :stripe | String.t()

  @spec default_provider() :: :stripe
  def default_provider do
    :stripe
  end

  @spec adapter(provider()) :: module()
  def adapter(provider) do
    case normalize_provider(provider) do
      :stripe -> Stripe
    end
  end

  @spec capabilities(provider()) :: map()
  def capabilities(provider) do
    adapter(provider).capabilities()
  end

  @spec create_intent(provider(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_intent(provider, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    adapter(provider).create_intent(attrs, opts)
  end

  @spec verify_webhook(provider(), map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_webhook(provider, headers, raw_body, opts \\ [])
      when is_map(headers) and is_binary(raw_body) and is_list(opts) do
    adapter(provider).verify_webhook(headers, raw_body, opts)
  end

  @spec normalize_webhook(provider(), map()) :: {:ok, term()} | {:error, term()}
  def normalize_webhook(provider, payload) when is_map(payload) do
    adapter(provider).normalize_webhook(payload)
  end

  @spec normalize_provider(provider()) :: :stripe
  def normalize_provider(provider) when provider in [:stripe, "stripe", "STRIPE"], do: :stripe
  def normalize_provider(_provider), do: :stripe
end
