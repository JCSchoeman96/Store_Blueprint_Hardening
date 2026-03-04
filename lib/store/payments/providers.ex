defmodule Store.Payments.Providers do
  @moduledoc """
  Provider adapter resolver and boundary wrapper.

  Resolution is fail-closed: unknown providers are rejected and never routed
  to an implicit fallback adapter.
  """

  alias Store.Payments.Providers.{PayFast, Paystack, PeachPayments, Stripe, Yoco}
  alias Store.Support.Errors.Error

  @type known_provider :: :stripe | :payfast | :paystack | :yoco | :peach_payments
  @type normalized_provider :: known_provider() | :unknown
  @type provider :: known_provider() | String.t()

  @provider_aliases %{
    "stripe" => :stripe,
    "payfast" => :payfast,
    "paystack" => :paystack,
    "yoco" => :yoco,
    "peach" => :peach_payments,
    "peach_payments" => :peach_payments,
    "peach-payments" => :peach_payments
  }

  @spec adapter(provider()) :: {:ok, module()} | {:error, Error.t()}
  def adapter(provider) do
    case normalize_provider(provider) do
      :stripe -> {:ok, Stripe}
      :payfast -> {:ok, PayFast}
      :paystack -> {:ok, Paystack}
      :yoco -> {:ok, Yoco}
      :peach_payments -> {:ok, PeachPayments}
      :unknown -> {:error, unsupported_provider_error(provider)}
    end
  end

  @spec capabilities(provider()) :: map() | {:error, Error.t()}
  def capabilities(provider) do
    case adapter(provider) do
      {:ok, module} -> module.capabilities()
      {:error, error} -> {:error, error}
    end
  end

  @spec create_intent(provider(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_intent(provider, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, module} <- adapter(provider) do
      module.create_intent(attrs, opts)
    end
  end

  @spec verify_webhook(provider(), map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_webhook(provider, headers, raw_body, opts \\ [])
      when is_map(headers) and is_binary(raw_body) and is_list(opts) do
    with {:ok, module} <- adapter(provider) do
      module.verify_webhook(headers, raw_body, opts)
    end
  end

  @spec normalize_webhook(provider(), map()) :: {:ok, term()} | {:error, term()}
  def normalize_webhook(provider, payload) when is_map(payload) do
    with {:ok, module} <- adapter(provider) do
      module.normalize_webhook(payload)
    end
  end

  @spec normalize_provider(provider()) :: normalized_provider()
  def normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  def normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@provider_aliases, &1, :unknown))
  end

  def normalize_provider(_provider), do: :unknown

  defp unsupported_provider_error(provider) do
    Error.new("PAYMENT_EVENT_UNKNOWN", "unsupported payment provider", %{
      provider: inspect(provider)
    })
  end
end
