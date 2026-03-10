defmodule Store.TestSupport.StripeAPIStub do
  @moduledoc false

  import ExUnit.Assertions

  alias Store.Perf.ChaosProfile

  @stub_name Store.Payments.Providers.Stripe
  @chaos_override_key :stripe_perf_chaos_override

  def req_options, do: [plug: {Req.Test, Store.Payments.Providers.Stripe}]

  def setup_default(context \\ %{}) do
    :ok = Req.Test.set_req_test_from_context(context)
    :ok = Req.Test.verify_on_exit!(context)
    stub_default()
    :ok
  end

  def stub_default do
    Req.Test.stub(@stub_name, fn conn ->
      params = form_params(conn)
      endpoint = endpoint_key(conn.request_path)

      respond_default(conn, params, endpoint)
    end)
  end

  def with_chaos_override(override, fun) when is_map(override) and is_function(fun, 0) do
    previous = Application.get_env(:store, @chaos_override_key)
    Application.put_env(:store, @chaos_override_key, override)

    try do
      fun.()
    after
      restore_override(previous)
    end
  end

  def with_chaos_override(_override, fun) when is_function(fun, 0), do: fun.()

  def clear_chaos_override do
    Application.delete_env(:store, @chaos_override_key)
    :ok
  end

  def stub_payment_intent(fun) when is_function(fun, 2) do
    Req.Test.stub(@stub_name, fn conn ->
      params = form_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/v1/payment_intents"} ->
          fun.(conn, params)

        {"POST", "/v1/checkout/sessions"} ->
          Req.Test.json(conn, checkout_session_response(params))

        {"POST", "/v1/setup_intents"} ->
          Req.Test.json(conn, setup_intent_response(params))

        _ ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"message" => "unexpected stripe path"}})
      end
    end)
  end

  def form_params(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    assert Plug.Conn.get_req_header(conn, "authorization") != []
    assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
    assert Plug.Conn.get_req_header(conn, "stripe-version") != []

    URI.decode_query(body)
  end

  def checkout_session_response(params, overrides \\ %{}) do
    mode = Map.get(params, "mode", "payment")
    local_intent_id = Map.get(params, "metadata[local_intent_id]", "pi_local_test")
    provider_session_id = "cs_test_#{short_hash(local_intent_id)}"

    payment_intent_id =
      if mode == "payment", do: "pi_test_#{short_hash(local_intent_id)}", else: nil

    Map.merge(
      %{
        "customer" => "cus_test_#{short_hash(local_intent_id)}",
        "id" => provider_session_id,
        "mode" => mode,
        "payment_intent" => payment_intent_id,
        "url" => "https://checkout.stripe.test/session/#{provider_session_id}"
      },
      overrides
    )
  end

  def setup_intent_response(params, overrides \\ %{}) do
    local_intent_id = Map.get(params, "metadata[local_intent_id]", "pi_local_test")
    provider_payment_id = "seti_test_#{short_hash(local_intent_id)}"

    Map.merge(
      %{
        "client_secret" => "#{provider_payment_id}_secret_test",
        "customer" => Map.get(params, "customer"),
        "id" => provider_payment_id,
        "metadata" => %{
          "currency" => Map.get(params, "metadata[currency]", "USD"),
          "local_intent_id" => local_intent_id,
          "subscription_id" => Map.get(params, "metadata[subscription_id]")
        },
        "status" => "requires_payment_method"
      },
      overrides
    )
  end

  def payment_intent_response(params, overrides \\ %{}) do
    local_intent_id = Map.get(params, "metadata[local_intent_id]", "pi_local_test")
    provider_payment_id = "pi_test_#{short_hash(local_intent_id)}"

    Map.merge(
      %{
        "amount" => Map.get(params, "amount", "0") |> String.to_integer(),
        "client_secret" => "#{provider_payment_id}_secret_test",
        "currency" => Map.get(params, "currency", "usd"),
        "customer" => Map.get(params, "customer"),
        "id" => provider_payment_id,
        "metadata" => %{
          "local_intent_id" => local_intent_id,
          "order_id" => Map.get(params, "metadata[order_id]"),
          "renewal_attempt_id" => Map.get(params, "metadata[renewal_attempt_id]"),
          "renewal_key" => Map.get(params, "metadata[renewal_key]"),
          "subscription_id" => Map.get(params, "metadata[subscription_id]")
        },
        "payment_method" => Map.get(params, "payment_method"),
        "status" => "succeeded"
      },
      overrides
    )
  end

  def payment_intent_error(conn, params, payment_status, code, message, http_status \\ 402) do
    payment_intent = payment_intent_response(params, %{"status" => payment_status})

    conn
    |> Plug.Conn.put_status(http_status)
    |> Req.Test.json(%{
      "error" => %{
        "code" => code,
        "message" => message,
        "payment_intent" => payment_intent
      }
    })
  end

  defp resolve_action(endpoint, params) do
    override = Application.get_env(:store, @chaos_override_key, %{})

    profile =
      override
      |> Map.get(:profile, ChaosProfile.current_profile())
      |> ChaosProfile.normalize_profile()

    seed = Map.get(override, :seed, ChaosProfile.current_seed())
    request_key = ChaosProfile.request_key(endpoint, params)

    case Map.get(override, :mode) do
      :slow ->
        {:ok, ChaosProfile.fault_delay_ms(profile, :slow, seed, request_key, delay_ms(override))}

      :timeout ->
        {:timeout,
         ChaosProfile.fault_delay_ms(profile, :timeout, seed, request_key, delay_ms(override))}

      :error ->
        {:error,
         ChaosProfile.fault_delay_ms(profile, :error, seed, request_key, delay_ms(override))}

      _ ->
        {:ok, ChaosProfile.standard_provider_delay_ms(profile, seed, endpoint, request_key)}
    end
  end

  defp delay_ms(override) do
    case Map.get(override, :delay_ms, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp timeout_response(conn, endpoint) do
    conn
    |> Plug.Conn.put_status(408)
    |> Req.Test.json(%{
      "error" => %{
        "code" => "timeout",
        "message" => "stripe #{endpoint} timed out"
      }
    })
  end

  defp provider_error_response(conn, endpoint) do
    conn
    |> Plug.Conn.put_status(503)
    |> Req.Test.json(%{
      "error" => %{
        "code" => "provider_down",
        "message" => "stripe #{endpoint} is unavailable"
      }
    })
  end

  defp restore_override(nil), do: Application.delete_env(:store, @chaos_override_key)
  defp restore_override(previous), do: Application.put_env(:store, @chaos_override_key, previous)

  defp respond_default(conn, params, endpoint) do
    case {conn.method, conn.request_path} do
      {"POST", "/v1/checkout/sessions"} ->
        respond_for_action(conn, endpoint, params, &checkout_session_response/1)

      {"POST", "/v1/setup_intents"} ->
        respond_for_action(conn, endpoint, params, &setup_intent_response/1)

      {"POST", "/v1/payment_intents"} ->
        respond_for_action(conn, endpoint, params, &payment_intent_response/1)

      _ ->
        unexpected_path_response(conn)
    end
  end

  defp respond_for_action(conn, endpoint, params, success_fun) do
    case resolve_action(endpoint, params) do
      {:ok, delay_ms} ->
        maybe_sleep(delay_ms)
        Req.Test.json(conn, success_fun.(params))

      {:timeout, delay_ms} ->
        maybe_sleep(delay_ms)
        timeout_response(conn, endpoint)

      {:error, delay_ms} ->
        maybe_sleep(delay_ms)
        provider_error_response(conn, endpoint)
    end
  end

  defp unexpected_path_response(conn) do
    conn
    |> Plug.Conn.put_status(404)
    |> Req.Test.json(%{"error" => %{"message" => "unexpected stripe path"}})
  end

  defp maybe_sleep(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.sleep(delay_ms)
  end

  defp maybe_sleep(_delay_ms), do: :ok

  defp endpoint_key("/v1/checkout/sessions"), do: "checkout_sessions"
  defp endpoint_key("/v1/setup_intents"), do: "setup_intents"
  defp endpoint_key("/v1/payment_intents"), do: "payment_intents"
  defp endpoint_key(other), do: other

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
