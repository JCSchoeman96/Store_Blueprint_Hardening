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
  @type enabled_provider_config :: [provider()] | String.t() | nil

  @known_providers [:stripe, :payfast, :paystack, :yoco, :peach_payments]

  @provider_aliases %{
    "stripe" => :stripe,
    "payfast" => :payfast,
    "paystack" => :paystack,
    "yoco" => :yoco,
    "peach" => :peach_payments,
    "peach_payments" => :peach_payments,
    "peach-payments" => :peach_payments
  }

  @spec known_providers() :: [known_provider()]
  def known_providers do
    Enum.map(@known_providers, & &1)
  end

  @spec known_provider?(term()) :: boolean()
  def known_provider?(provider), do: provider in @known_providers

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

  @spec normalize_enabled_providers(enabled_provider_config()) ::
          {:ok, [known_provider()]} | {:error, Error.t()}
  def normalize_enabled_providers(nil), do: {:ok, []}

  def normalize_enabled_providers(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> normalize_enabled_provider_list()
  end

  def normalize_enabled_providers(value) when is_list(value),
    do: normalize_enabled_provider_list(value)

  def normalize_enabled_providers(_value) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "enabled payment providers config must be a comma-separated string or list"
     )}
  end

  @spec enabled_providers() :: [known_provider()]
  def enabled_providers do
    config_value =
      :store
      |> Application.get_env(:payments, [])
      |> Keyword.get(:enabled_providers, [])

    case normalize_enabled_providers(config_value) do
      {:ok, providers} -> providers
      {:error, _error} -> []
    end
  end

  @spec default_purchase_provider_for_ui() :: known_provider() | nil
  def default_purchase_provider_for_ui do
    configured =
      :store
      |> Application.get_env(:payments, [])
      |> Keyword.get(:default_purchase_provider_for_ui)

    enabled = enabled_providers()

    case normalize_provider(configured) do
      known when known in @known_providers ->
        if known in enabled, do: known, else: nil

      _ ->
        nil
    end
  end

  @spec ensure_enabled_provider(known_provider()) :: :ok | {:error, Error.t()}
  def ensure_enabled_provider(provider) when provider in @known_providers do
    if provider in enabled_providers() do
      :ok
    else
      {:error,
       Error.new("PAYMENT_PROVIDER_DISABLED", "payment provider is disabled", %{
         provider: Atom.to_string(provider),
         enabled_providers: supported_enabled_providers()
       })}
    end
  end

  def ensure_enabled_provider(provider), do: {:error, unsupported_provider_error(provider)}

  @spec selection_required_error() :: Error.t()
  def selection_required_error do
    Error.new("PAYMENT_PROVIDER_SELECTION_REQUIRED", "payment provider selection is required", %{
      supported_providers: supported_providers()
    })
  end

  defp unsupported_provider_error(provider) do
    Error.new("PAYMENT_PROVIDER_UNSUPPORTED", "unsupported payment provider", %{
      provider: provider_metadata(provider),
      supported_providers: supported_providers()
    })
  end

  defp normalize_enabled_provider_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_provider(value) do
        known when known in @known_providers ->
          {:cont, {:ok, [known | acc]}}

        :unknown ->
          {:halt,
           {:error,
            Error.new(
              "PAYMENT_PROVIDER_UNSUPPORTED",
              "enabled payment provider is unsupported",
              %{
                provider: provider_metadata(value),
                supported_providers: supported_providers()
              }
            )}}
      end
    end)
    |> case do
      {:ok, providers} ->
        {:ok, providers |> Enum.reverse() |> Enum.uniq()}

      {:error, error} ->
        {:error, error}
    end
  end

  defp supported_providers do
    Enum.map(@known_providers, &Atom.to_string/1)
  end

  defp supported_enabled_providers do
    enabled_providers()
    |> Enum.map(&Atom.to_string/1)
  end

  defp provider_metadata(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_metadata(provider) when is_binary(provider), do: String.trim(provider)
  defp provider_metadata(provider), do: inspect(provider)
end
