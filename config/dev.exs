import Config

# GF-704: Repo password comes from .env via Dotenvy in config/runtime.exs.
# Dotenvy can't live here — compile-time config is evaluated before deps load.
config :span_chain, SpanChain.Repo,
  username: "postgres",
  hostname: "localhost",
  database: "span_chain_dev",
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

config :span_chain, SpanChain.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true,
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  watchers: []

# GF-771: Intentional dev fallback — never used in :prod (runtime.exs overrides via GF_API_KEY)
config :span_chain, :api_key, "dev-secret-change-me"

config :logger, :default_handler, level: :info
