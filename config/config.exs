# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :store,
  ecto_repos: [Store.Repo],
  ash_domains: [
    Store.Accounts,
    Store.Admin,
    Store.Catalog,
    Store.Carts,
    Store.Comms,
    Store.Digital,
    Store.Checkout,
    Store.Orders,
    Store.Payments,
    Store.Fulfillment,
    Store.Shipping,
    Store.Pricing
  ],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :store, StoreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: StoreWeb.ErrorHTML, json: StoreWeb.ErrorJSON, jsonapi: StoreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Store.PubSub,
  live_view: [signing_salt: "33Mw/8JS"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :store, Store.Mailer, adapter: Swoosh.Adapters.Local

config :store, :payments,
  checkout: [
    return_base_url: "http://localhost:4000/checkout/return",
    cancel_base_url: "http://localhost:4000/checkout/cancel"
  ],
  stripe: [
    checkout_base_url: "https://checkout.stripe.example"
  ]

config :store, :comms,
  default_provider: :swoosh,
  from_name: "Store",
  from_email: "no-reply@store.local",
  support_email: "support@store.local",
  req_postmark: [
    url: "https://api.postmarkapp.com/email",
    server_token: nil,
    from_name: "Store",
    from_email: "no-reply@store.local"
  ]

config :store, :digital,
  storage_provider: :fake,
  signed_url_ttl_seconds: 120,
  default_grant_ttl_days: 30,
  default_max_downloads: nil,
  refund_revocation_policy: :strict_line_scoped,
  fake_host: "downloads.local",
  allowed_redirect_hosts: ["downloads.local"]

config :store, :rate_limit,
  backend: Store.Support.RateLimit.EtsBackend,
  signed_download_limit: 10,
  signed_download_window_seconds: 60

config :store, Oban,
  repo: Store.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Store.Workers.ExpireInventoryReservationsWorker},
       {"*/5 * * * *", Store.Workers.ReclaimStaleEmailOutboxWorker}
     ]}
  ],
  queues: [webhooks: 10, inventory: 10, refunds: 10, comms: 10, fulfillment: 10, digital: 10]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  store: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  store: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# JSON:API media type support for accepts/content-negotiation.
config :mime, :types, %{
  "application/vnd.api+json" => ["jsonapi"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
