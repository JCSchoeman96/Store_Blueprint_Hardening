defmodule Store.TestSupport.StripeAPIStub do
  @moduledoc false

  import ExUnit.Assertions

  @stub_name Store.Payments.Providers.Stripe

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

      case {conn.method, conn.request_path} do
        {"POST", "/v1/checkout/sessions"} ->
          Req.Test.json(conn, checkout_session_response(params))

        {"POST", "/v1/setup_intents"} ->
          Req.Test.json(conn, setup_intent_response(params))

        {"POST", "/v1/payment_intents"} ->
          Req.Test.json(conn, payment_intent_response(params))

        _ ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"message" => "unexpected stripe path"}})
      end
    end)
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

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
