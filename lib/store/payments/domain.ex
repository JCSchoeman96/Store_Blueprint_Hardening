defmodule Store.Payments do
  @moduledoc """
  Payments domain for payment lifecycle, provider events, and refunds.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Store.Checkout
  alias Store.Digital.Facade, as: DigitalFacade
  alias Store.Payments.Inputs.CreateIntentForOrderInput
  alias Store.Payments.{Interlocks, Providers, Refunds}
  alias Store.Support.Errors.{Error, Normalize}
  alias Store.Support.Telemetry.RepoStats

  resources do
    resource(Store.Payments.PaymentIntent)
    resource(Store.Payments.PaymentAttempt)
    resource(Store.Payments.ProviderEvent)
    resource(Store.Payments.Refund)
    resource(Store.Payments.RefundAttempt)
    resource(Store.Payments.WebhookReceipt)
  end

  json_api do
    prefix("/api/v1")
    show_raised_errors?(false)

    routes do
      base_route("/admin/payment-intents", Store.Payments.PaymentIntent) do
        index(:read_for_admin, derive_filter?: false, derive_sort?: false)
        get(:get_for_admin, derive_filter?: false, derive_sort?: false)
      end
    end
  end

  @spec request_refund(map(), keyword()) :: {:ok, Store.Payments.Refund.t()} | {:error, term()}
  def request_refund(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Refunds.request_refund(attrs, opts)
  end

  @spec process_refund_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_refund_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Refunds.process_refund_webhook_receipt(receipt, opts)
  end

  @spec create_or_reuse_payment_intent(map(), keyword()) ::
          {:ok,
           %{
             payment_intent: Store.Payments.PaymentIntent.t(),
             payment_intent_key: String.t(),
             duplicate?: boolean()
           }}
          | {:error, term()}
  def create_or_reuse_payment_intent(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Interlocks.create_or_reuse_payment_intent(attrs, opts)
  end

  @spec create_intent_for_order(map() | nil, String.t(), CreateIntentForOrderInput.t()) ::
          {:ok,
           %{
             order_id: Ecto.UUID.t(),
             order_ref: String.t(),
             payment_intent_id: Ecto.UUID.t(),
             payment_intent_key: String.t(),
             provider: String.t(),
             provider_session_id: String.t() | nil,
             state: atom(),
             amount_minor: non_neg_integer(),
             currency: String.t(),
             checkout_key: String.t(),
             redirect_url: String.t() | nil,
             client_secret: String.t() | nil,
             duplicate?: boolean()
           }}
          | {:error, Error.t()}
  def create_intent_for_order(actor, checkout_key, %CreateIntentForOrderInput{} = input)
      when is_binary(checkout_key) do
    started_at = System.monotonic_time()

    {result, repo_stats} =
      RepoStats.capture(fn ->
        with {:ok, checkout} <- Checkout.get_payment_context_for_user(actor, checkout_key),
             :ok <-
               DigitalFacade.ensure_checkout_actor_allowed_for_system(actor, checkout.order_id),
             :ok <- ensure_totals_finalized(checkout),
             :ok <- ensure_order_pending_payment(checkout),
             :ok <- ensure_payable_total(checkout),
             :ok <- Providers.ensure_enabled_provider(input.provider),
             {:ok, intent_result} <- create_or_reuse_intent_for_checkout(checkout, input),
             {:ok, payment_intent} <-
               ensure_provider_reference(
                 intent_result.payment_intent,
                 checkout,
                 intent_result.payment_intent_key,
                 input
               ),
             {:ok, submitted_intent} <- maybe_submit_payment_intent(payment_intent) do
          {:ok, build_checkout_intent_result(checkout, intent_result, submitted_intent)}
        end
      end)

    :telemetry.execute(
      [:store, :checkout, :create_payment_intent],
      %{duration: System.monotonic_time() - started_at},
      %{provider: provider_to_string(input.provider), result: telemetry_result(result)}
    )

    :telemetry.execute(
      [:store, :checkout, :step],
      %{
        duration: System.monotonic_time() - started_at,
        query_count: repo_stats.query_count,
        queue_time: repo_stats.queue_time,
        query_time: repo_stats.query_time,
        decode_time: repo_stats.decode_time
      },
      %{
        step: :create_payment_intent,
        provider: provider_to_string(input.provider),
        result: telemetry_result(result)
      }
    )

    normalize_result(result)
  end

  def create_intent_for_order(_actor, _checkout_key, _input) do
    {:error, Error.new("VALIDATION_ERROR", "checkout_key and create intent input are required")}
  end

  @spec process_payment_webhook_receipt(Store.Payments.WebhookReceipt.t(), keyword()) ::
          :ok | {:discard, String.t()} | {:error, term()}
  def process_payment_webhook_receipt(receipt, opts \\ []) when is_list(opts) do
    Interlocks.process_payment_webhook_receipt(receipt, opts)
  end

  @spec apply_payment_success_once(Store.Payments.PaymentIntent.t() | String.t(), keyword()) ::
          {:ok,
           %{
             applied?: boolean(),
             order: Store.Orders.Order.t(),
             payment_intent: Store.Payments.PaymentIntent.t()
           }}
          | {:error, term()}
  def apply_payment_success_once(payment_intent_or_id, opts \\ []) when is_list(opts) do
    Interlocks.apply_payment_success_once(payment_intent_or_id, opts)
  end

  defp create_or_reuse_intent_for_checkout(checkout, input) do
    attrs = %{
      order_id: checkout.order_id,
      amount_received_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      provider: input.provider
    }

    create_or_reuse_payment_intent(attrs, context: %{system?: true})
  end

  defp ensure_provider_reference(payment_intent, checkout, payment_intent_key, input) do
    if provider_reference_present?(payment_intent) do
      {:ok, payment_intent}
    else
      with {:ok, provider_payload} <-
             Providers.create_intent(
               input.provider,
               provider_create_intent_attrs(checkout, payment_intent_key),
               []
             ) do
        update_provider_reference(payment_intent, provider_payload, input.provider)
      end
    end
  end

  defp provider_create_intent_attrs(checkout, payment_intent_key) do
    urls = provider_return_urls(checkout.checkout_key)

    %{
      order_ref: checkout.order_ref,
      order_id: checkout.order_id,
      checkout_key: checkout.checkout_key,
      amount_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      payment_intent_key: payment_intent_key,
      idempotency_key: payment_intent_key,
      return_url: urls.return_url,
      cancel_url: urls.cancel_url
    }
  end

  defp provider_return_urls(checkout_key) do
    payments_config = Application.get_env(:store, :payments, [])
    checkout_config = Keyword.get(payments_config, :checkout, [])

    return_base_url =
      Keyword.get(checkout_config, :return_base_url, "http://localhost:4000/checkout/return")

    cancel_base_url =
      Keyword.get(checkout_config, :cancel_base_url, "http://localhost:4000/checkout/cancel")

    %{
      return_url: append_checkout_key(return_base_url, checkout_key),
      cancel_url: append_checkout_key(cancel_base_url, checkout_key)
    }
  end

  defp append_checkout_key(base_url, checkout_key)
       when is_binary(base_url) and is_binary(checkout_key) do
    separator = if String.contains?(base_url, "?"), do: "&", else: "?"
    "#{base_url}#{separator}checkout_key=#{checkout_key}"
  end

  defp update_provider_reference(payment_intent, provider_payload, provider)
       when is_map(provider_payload) do
    provider_value =
      Map.get(provider_payload, :provider, provider)

    case Providers.normalize_provider(provider_value) do
      :unknown ->
        {:error,
         Error.new(
           "PAYMENT_PROVIDER_UNSUPPORTED",
           "payment provider is not supported"
         )}

      normalized ->
        if Providers.known_provider?(normalized) do
          attrs = %{
            provider: normalized,
            provider_payment_id: Map.get(provider_payload, :provider_payment_id),
            provider_session_id: Map.get(provider_payload, :provider_session_id),
            provider_checkout_url: Map.get(provider_payload, :provider_checkout_url),
            provider_client_secret: Map.get(provider_payload, :provider_client_secret)
          }

          payment_intent
          |> Ash.Changeset.for_update(:set_provider_reference, attrs, context: %{system?: true})
          |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
        else
          {:error,
           Error.new(
             "PAYMENT_PROVIDER_UNSUPPORTED",
             "payment provider is not supported"
           )}
        end
    end
  end

  defp maybe_submit_payment_intent(
         %Store.Payments.PaymentIntent{state: :created} = payment_intent
       ) do
    payment_intent
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update(domain: __MODULE__, authorize?: false, context: %{system?: true})
  end

  defp maybe_submit_payment_intent(%Store.Payments.PaymentIntent{state: state} = payment_intent)
       when state in [:submitted, :requires_action, :succeeded] do
    {:ok, payment_intent}
  end

  defp maybe_submit_payment_intent(_payment_intent) do
    {:error,
     Error.new(
       "PAYMENT_EVENT_UNVERIFIED",
       "payment intent cannot be submitted from the current state"
     )}
  end

  defp build_checkout_intent_result(checkout, intent_result, payment_intent) do
    %{
      order_id: checkout.order_id,
      order_ref: checkout.order_ref,
      payment_intent_id: payment_intent.id,
      payment_intent_key: intent_result.payment_intent_key,
      provider: provider_to_string(payment_intent.provider),
      provider_session_id: payment_intent.provider_session_id,
      state: payment_intent.state,
      amount_minor: checkout.grand_total_minor,
      currency: checkout.currency_code,
      checkout_key: checkout.checkout_key,
      redirect_url: payment_intent.provider_checkout_url,
      client_secret: payment_intent.provider_client_secret,
      duplicate?: intent_result.duplicate?
    }
  end

  defp ensure_totals_finalized(%{totals_finalized?: true}), do: :ok

  defp ensure_totals_finalized(_checkout) do
    {:error,
     Error.new(
       "VALIDATION_ERROR",
       "checkout totals must be finalized before payment intent creation"
     )}
  end

  defp ensure_order_pending_payment(%{state: :pending_payment}), do: :ok

  defp ensure_order_pending_payment(%{state: :paid}),
    do: {:error, Error.new("PAYMENT_ALREADY_SUCCEEDED", "order is already paid")}

  defp ensure_order_pending_payment(_checkout) do
    {:error, Error.new("PAYMENT_EVENT_UNVERIFIED", "order is not payable in the current state")}
  end

  defp ensure_payable_total(%{grand_total_minor: amount, currency_code: currency})
       when is_integer(amount) and amount >= 0 and is_binary(currency) and currency != "",
       do: :ok

  defp ensure_payable_total(_checkout) do
    {:error, Error.new("VALIDATION_ERROR", "checkout totals are invalid")}
  end

  defp provider_reference_present?(%Store.Payments.PaymentIntent{} = payment_intent) do
    is_binary(payment_intent.provider_session_id) or
      is_binary(payment_intent.provider_payment_id) or
      is_binary(payment_intent.provider_checkout_url) or
      is_binary(payment_intent.provider_client_secret)
  end

  defp provider_to_string(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.downcase()

  defp provider_to_string(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp provider_to_string(_provider), do: "unknown"

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, error}), do: {:error, Normalize.normalize(error)}

  defp telemetry_result({:ok, %{duplicate?: true}}), do: :duplicate
  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result({:error, _}), do: :error
end
