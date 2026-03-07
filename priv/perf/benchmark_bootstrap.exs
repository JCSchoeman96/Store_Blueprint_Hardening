if Mix.env() != :test do
  raise "benchmark_bootstrap.exs must be run with MIX_ENV=test"
end

if Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} -> app == :store end) do
  raise """
  benchmark_bootstrap.exs expects standalone startup.
  Run with: MIX_ENV=test mix run --no-start priv/perf/benchmark_bootstrap.exs
  """
end

repo_config = Application.get_env(:store, Store.Repo, [])
direct_repo_config = Application.get_env(:store, Store.DirectRepo, [])

Application.put_env(
  :store,
  Store.Repo,
  Keyword.merge(repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size: 20,
    prepare: :unnamed,
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

Application.put_env(
  :store,
  Store.DirectRepo,
  Keyword.merge(direct_repo_config,
    pool: DBConnection.ConnectionPool,
    pool_size: 10,
    queue_target: 10_000,
    queue_interval: 10_000,
    timeout: 60_000
  )
)

Application.put_env(:store, Oban,
  repo: Store.DirectRepo,
  testing: :manual,
  plugins: false,
  queues: false
)

{:ok, _} = Application.ensure_all_started(:store)

defmodule Store.Perf.BenchmarkBootstrap do
  @moduledoc false

  alias Store.Carts.Facade, as: CartsFacade
  alias Store.Carts.Inputs.CartItemInput
  alias Store.Checkout
  alias Store.Checkout.Inputs.{CheckoutShippingInput, CheckoutStartInput}
  alias Store.Payments.Providers
  alias Store.Shipping.Facade, as: ShippingFacade
  alias Store.Shipping.Inputs.QuoteRequest
  alias Store.Shipping.{ShippingMethod, ShippingRateRule, ShippingZone}
  alias Store.Pricing.TaxRate
  alias Store.TestFixtures

  @hot_storefront_count 5
  @distributed_checkout_count 12
  @prepared_checkout_count 12

  def build do
    admin = create_admin!()
    storefront_products = create_products!(admin, @hot_storefront_count, "phase30-hot")
    flash_sale = create_products!(admin, 1, "phase30-flash") |> hd()
    checkout_products = create_products!(admin, @distributed_checkout_count, "phase30-checkout")
    pricing = create_pricing_rules!()
    prepared_checkouts = create_prepared_checkouts!(checkout_products, pricing)
    browser_ready_checkout = create_browser_ready_checkout!(checkout_products, pricing)

    webhook_payload = stripe_event_fixture("evt_phase30_webhook", "payment_intent.succeeded")
    callback_payload = stripe_event_fixture("evt_phase30_callback", "payment_intent.succeeded")

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      base_url: System.get_env("STORE_BENCHMARK_BASE_URL", "http://127.0.0.1:4000"),
      storefront: %{
        hot_slugs: Enum.map(storefront_products, & &1.slug),
        flash_sale_slug: flash_sale.slug
      },
      checkout: %{
        distributed_slugs: Enum.map(checkout_products, & &1.slug),
        distributed_variant_ids: Enum.map(checkout_products, & &1.variant_id),
        prepared_paths:
          Enum.map(prepared_checkouts, fn checkout ->
            %{
              path: "/checkout?checkout_key=#{checkout.checkout_key}",
              cart_token: checkout.cart_token
            }
          end),
        browser_ready_checkout: %{
          product_slug: hd(checkout_products).slug,
          checkout_path: "/checkout?checkout_key=#{browser_ready_checkout.checkout_key}",
          cart_token: browser_ready_checkout.cart_token
        },
        shipping_form: %{
          recipient_name: "Phase 30 Customer",
          address_line1: "1 Main St",
          city: "San Francisco",
          country_code: "US",
          region_code: "CA",
          postal_code: "94105",
          phone: "555-555-1212",
          shipping_method_code: pricing.selection.shipping_method_code,
          quote_hash: pricing.selection.quote_hash
        }
      },
      webhook_ingress: %{
        webhook: webhook_request_fixture("/api/webhooks/stripe", webhook_payload),
        callback: webhook_request_fixture("/api/payments/stripe/callback", callback_payload)
      }
    }
  end

  def write!(path) when is_binary(path) do
    payload = build()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
    payload
  end

  defp create_admin! do
    email = "phase30_perf_admin_#{System.unique_integer([:positive, :monotonic])}@example.com"
    admin = TestFixtures.register_user!(email: email)
    _role = TestFixtures.assign_role!(admin, :admin)
    admin
  end

  defp create_products!(admin, count, prefix) do
    Enum.map(1..count, fn idx ->
      product =
        Store.Catalog.Product
        |> Ash.Changeset.for_create(
          :create_draft,
          %{
            slug: "#{prefix}-#{System.unique_integer([:positive])}",
            title: "Phase 30 #{prefix} #{idx}",
            base_variant_sku: "P30-#{prefix}-#{System.unique_integer([:positive])}",
            base_variant_currency_code: "USD",
            base_variant_price_minor: 2_000,
            base_variant_stock_on_hand: 50_000
          }
        )
        |> Ash.create!(domain: Store.Catalog, actor: admin)

      published =
        product
        |> Ash.Changeset.for_update(:publish, %{})
        |> Ash.update!(domain: Store.Catalog, actor: admin)

      %{slug: published.slug, variant_id: published.default_variant_id}
    end)
  end

  defp create_pricing_rules! do
    unique = System.unique_integer([:positive])

    method =
      ShippingMethod
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND-P30-#{unique}",
          name: "Ground P30 #{unique}",
          active: true,
          requires_address: true,
          sort_order: 100
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    zone =
      ShippingZone
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "US-CA-P30-#{unique}",
          country_code: "US",
          region_code: "CA",
          active: true
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _rule =
      ShippingRateRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "GROUND_RULE_P30_#{unique}",
          shipping_zone_id: zone.id,
          shipping_method_id: method.id,
          currency: "USD",
          shipping_cost_minor: 500,
          active: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Shipping, authorize?: false, context: %{system?: true})

    _tax_rate =
      TaxRate
      |> Ash.Changeset.for_create(
        :create,
        %{
          code: "P30-CA-#{unique}",
          country_code: "US",
          region_code: "CA",
          rate_basis_points: 725,
          active: true,
          product_tax_category: "STANDARD",
          shipping_taxable: true,
          precedence_rank: 10
        },
        context: %{system?: true}
      )
      |> Ash.create!(domain: Store.Pricing, authorize?: false, context: %{system?: true})

    selection = quote_selection!()
    %{selection: selection}
  end

  defp create_prepared_checkouts!(checkout_products, pricing) do
    Enum.map(1..@prepared_checkout_count, fn idx ->
      product = Enum.at(checkout_products, rem(idx - 1, length(checkout_products)))
      token = Ash.UUIDv7.generate()
      actor = %{cart_token: token}

      {:ok, add_input} = CartItemInput.new(%{"variant_id" => product.variant_id, "qty" => 1})
      {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)
      {:ok, start_input} = CheckoutStartInput.new(%{})
      {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

      %{
        cart_token: token,
        checkout_key: start_result.checkout_key,
        variant_id: product.variant_id,
        actor: actor,
        pricing: pricing
      }
    end)
  end

  defp create_browser_ready_checkout!(checkout_products, pricing) do
    product = hd(checkout_products)
    token = Ash.UUIDv7.generate()
    actor = %{cart_token: token}

    {:ok, add_input} = CartItemInput.new(%{"variant_id" => product.variant_id, "qty" => 1})
    {:ok, _cart} = CartsFacade.add_item_for_user(nil, token, add_input)
    {:ok, start_input} = CheckoutStartInput.new(%{})
    {:ok, start_result} = Checkout.start_from_cart(nil, token, start_input)

    {:ok, shipping_input} =
      CheckoutShippingInput.new(%{
        "recipient_name" => "Phase 30 Customer",
        "address_line1" => "1 Main St",
        "city" => "San Francisco",
        "country_code" => "US",
        "region_code" => "CA",
        "postal_code" => "94105",
        "phone" => "555-555-1212",
        "shipping_method_code" => pricing.selection.shipping_method_code,
        "quote_hash" => pricing.selection.quote_hash
      })

    {:ok, _checkout} = Checkout.set_shipping(actor, start_result.checkout_key, shipping_input)

    %{
      cart_token: token,
      checkout_key: start_result.checkout_key,
      variant_id: product.variant_id
    }
  end

  defp quote_selection! do
    {:ok, request} =
      QuoteRequest.new(%{
        destination_country_code: "US",
        destination_region_code: "CA",
        destination_postal_code: "94105",
        currency_code: "USD",
        shipping_weight_grams: 0
      })

    {:ok, [option | _]} = ShippingFacade.quote_options_for_system(request)
    %{quote_hash: option.quote_hash, shipping_method_code: option.shipping_method_code}
  end

  defp webhook_request_fixture(path, raw_body) do
    %{
      path: path,
      body: raw_body,
      headers: %{
        "content-type" => "application/json",
        "stripe-signature" => stripe_signature(raw_body)
      }
    }
  end

  defp stripe_event_fixture(event_id, event_type) do
    payment_provider = Providers.default_purchase_provider_for_ui() || :stripe
    provider_name = Atom.to_string(payment_provider)

    Jason.encode!(%{
      "id" => event_id,
      "type" => event_type,
      "data" => %{
        "object" => %{
          "id" => "pi_phase30_#{System.unique_integer([:positive])}",
          "checkout_session_id" => "cs_phase30_#{System.unique_integer([:positive])}",
          "amount_received" => 2_500,
          "currency" => "usd",
          "metadata" => %{
            "order_ref" => "P30-ORDER-#{System.unique_integer([:positive])}",
            "provider" => provider_name
          }
        }
      }
    })
  end

  defp stripe_signature(raw_body) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    secret =
      Application.get_env(:store, :payments, [])
      |> Keyword.get(:stripe, [])
      |> Keyword.fetch!(:webhook_secret)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end

output_path =
  System.get_env("STORE_BENCHMARK_DATA_PATH", "tmp/perf/benchmark_data.json")

payload = Store.Perf.BenchmarkBootstrap.write!(output_path)

IO.puts("Wrote benchmark bootstrap data to #{output_path}")
IO.puts("Flash-sale slug: #{payload.storefront.flash_sale_slug}")
