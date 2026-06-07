import Config

config :span_chain,
  ecto_repos: [SpanChain.Repo],
  http_port: 4000,
  trail_port: 4001,
  broadway_producer_module: SpanChain.Ingestion.BufferProducer,
  # GF-777: 1_000 → 100ms (low-volume p99 ~1034ms → ~100ms; SQLITE_BUSY obsolete po
  # GF-704). test.exs override-uje na 50ms seam; prod přepíše env var
  # BATCH_FLUSH_TIMEOUT_MS (config/runtime.exs).
  broadway_batch_timeout_ms: 100,
  ledger_module: SpanChain.Ledger,
  dead_letter_module: SpanChain.DeadLetter

# GF-704: Postgres defaults. Connection params (host/db/user) přicházejí per-env
# z dev.exs / test.exs / runtime.exs (prod). Adapter žije v repo.ex.
config :span_chain, SpanChain.Repo,
  pool_size: 10,
  queue_target: 50,
  queue_interval: 1000

config :span_chain, SpanChain.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SpanChain.Web.ErrorHTML],
    layout: false
  ],
  pubsub_server: SpanChain.PubSub,
  # GF-771: DEV/TEST ONLY hodnoty — NIKDY nepoužívat v produkci. Produkce injektuje
  # reálné secrets přes SECRET_KEY_BASE env var v config/runtime.exs (prod blok).
  live_view: [signing_salt: "dev-test-only-trail-salt"],
  secret_key_base: "dev_test_only_secret_key_base_NOT_FOR_PRODUCTION_set_SECRET_KEY_BASE_in_prod"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
