import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# In test we bypass PgBouncer and hit Postgres directly.
# Sandbox mode wraps each test in a transaction, making PgBouncer's
# transaction-mode pooling redundant and adding unnecessary latency.
config :store, Store.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "store_#{config_env()}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# 2. The Direct Route (Hits Postgres directly for Oban)
config :store, Store.DirectRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433, # Direct Port from your original setup
  database: "store_#{config_env()}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :store, :token_signing_secret, "test-store-token-signing-secret"

config :store, Oban,
  repo: Store.DirectRepo,
  testing: :manual,
  plugins: false,
  queues: false

config :store, :google_oauth,
  client_id: "test-google-client-id",
  client_secret: "test-google-client-secret",
  redirect_uri_base: "http://localhost:4000/auth"

config :store, :payments,
  enabled_providers: [:stripe],
  default_purchase_provider_for_ui: :stripe,
  stripe: [webhook_secret: "whsec_test_only_change_me"]

config :store, :shipping, quote_hash_secret: "phase22-test-only-change-me"

config :store, :digital,
  storage_provider: :fake,
  signed_url_ttl_seconds: 120,
  default_grant_ttl_days: 30,
  default_max_downloads: nil,
  refund_revocation_policy: :strict_line_scoped,
  fake_host: "downloads.local",
  allowed_redirect_hosts: ["downloads.local"]

rate_limit_backend =
  case System.get_env("STORE_RATE_LIMIT_BACKEND", "redis") do
    "ets" -> Store.Support.RateLimit.EtsBackend
    "redis" -> Store.Support.RateLimit.RedisBackend
    value -> raise "invalid STORE_RATE_LIMIT_BACKEND value: #{value}"
  end

redis_tls? = System.get_env("STORE_REDIS_SSL", "false") in ~w(true 1)

config :store, :rate_limit,
  backend: rate_limit_backend,
  redis_client: Store.Support.RateLimit.RedixClient,
  redis_name: :store_rate_limit_redis,
  # Use a dedicated Redis DB for tests; this should not be shared with dev/prod.
  redis: [
    host: System.get_env("STORE_REDIS_HOST", "localhost"),
    port: String.to_integer(System.get_env("STORE_REDIS_PORT", "6379")),
    database: String.to_integer(System.get_env("STORE_REDIS_TEST_DB", "1")),
    username: System.get_env("STORE_REDIS_USERNAME"),
    password: System.get_env("STORE_REDIS_PASSWORD"),
    ssl: redis_tls?
  ],
  signed_download_limit: 10,
  signed_download_window_seconds: 60

config :ash, :missed_notifications, :raise

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :store, StoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JDvVpYp2qPuf7v/Dw89FJQlWVqIElhblZfwxpATznRD+ivFRly3DWI5wokNzM2uF",
  server: false

# In test we don't send emails
config :store, Store.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
