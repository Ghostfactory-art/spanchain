import Config

# GF-704: Dotenvy lives here (runtime.exs), NOT in compile-time dev.exs/test.exs —
# Config.Reader evaluates compile-time config before deps are on the code path, so
# `import Dotenvy` there fails with "module Dotenvy is not loaded". Fully-qualified
# calls (no `import`) keep this prod-safe: dotenvy is `only: [:dev, :test]`, and the
# guarded branches below never execute in prod, so the module is never referenced.
if config_env() == :dev do
  Dotenvy.source!([".env", System.get_env()])

  config :span_chain, SpanChain.Repo, password: Dotenvy.env!("PGPASSWORD", :string, "postgres")
end

if config_env() == :test do
  Dotenvy.source!([".env.test", ".env", System.get_env()])

  config :span_chain, SpanChain.Repo, password: Dotenvy.env!("PGPASSWORD", :string, "postgres")
end

# GF-777: batch_timeout is tunable via the BATCH_FLUSH_TIMEOUT_MS env var, default 100ms.
# We INTENTIONALLY do not override the test env — the seam `broadway_batch_timeout_ms: 50`
# in config/test.exs must stay effective (GF-780: epoch_drain_timeout_ms 100ms >
# batch_timeout; equality/inversion yields a chain_broken race). runtime.exs runs AFTER
# the compile-time config, so an unguarded set would overwrite the 50ms seam.
if config_env() != :test do
  config :span_chain,
    broadway_batch_timeout_ms:
      System.get_env("BATCH_FLUSH_TIMEOUT_MS", "100") |> String.to_integer()
end

config :span_chain,
  trail_auth_enabled: System.get_env("TRAIL_AUTH_ENABLED") == "true"

if config_env() == :prod do
  # GF-771: production secrets come exclusively from env vars (fail-fast at startup
  # if missing). No hardcoded prod secret in the code or in git.
  config :span_chain, :api_key, System.fetch_env!("GF_API_KEY")

  # GF-783: the Phoenix Endpoint (port 4001) must serve from the OTP release. `mix
  # phx.server` does not exist in a release → set `server: true` explicitly. Bind 0.0.0.0 so
  # the port is reachable from the Docker network; `check_origin: false` for self-hosting behind
  # a reverse proxy / localhost.
  config :span_chain, SpanChain.Web.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: Application.get_env(:span_chain, :trail_port, 4001)],
    url: [host: System.get_env("PHX_HOST", "localhost")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    check_origin: false

  # GF-704: Postgres prod connection via DATABASE_URL (fail-fast if missing).
  # GF-783: SSL is opt-in via DATABASE_SSL (default off) — the Docker-internal Postgres
  # has no TLS; set DATABASE_SSL=true for a managed/remote Postgres that requires it.
  config :span_chain, SpanChain.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: System.get_env("DATABASE_SSL", "false") == "true"
end
