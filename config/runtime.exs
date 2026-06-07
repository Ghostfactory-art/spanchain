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

# GF-777: batch_timeout laditelný env varem BATCH_FLUSH_TIMEOUT_MS, default 100ms.
# Test env ZÁMĚRNĚ nepřebíjíme — seam `broadway_batch_timeout_ms: 50` v
# config/test.exs musí zůstat efektivní (GF-780: epoch_drain_timeout_ms 100ms >
# batch_timeout; rovnost/inverze vrací chain_broken race). runtime.exs běží PO
# compile-time configu, takže unguarded set by 50ms seam přepsal.
if config_env() != :test do
  config :span_chain,
    broadway_batch_timeout_ms:
      System.get_env("BATCH_FLUSH_TIMEOUT_MS", "100") |> String.to_integer()
end

if config_env() == :prod do
  # GF-771: produkční secrets jdou výhradně přes env vars (fail-fast při startu
  # pokud chybí). Žádný hardcoded prod secret v kódu ani gitu.
  config :span_chain, :api_key, System.fetch_env!("GF_API_KEY")

  # GF-783: Phoenix Endpoint (port 4001) musí servírovat z OTP release. `mix
  # phx.server` v releasu neexistuje → `server: true` explicitně. Bind 0.0.0.0 aby
  # byl port dosažitelný z Docker sítě; `check_origin: false` pro self-hosting za
  # reverse proxy / localhost.
  config :span_chain, SpanChain.Web.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: Application.get_env(:span_chain, :trail_port, 4001)],
    url: [host: System.get_env("PHX_HOST", "localhost")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    check_origin: false

  # GF-704: Postgres prod connection přes DATABASE_URL (fail-fast pokud chybí).
  # GF-783: SSL je opt-in přes DATABASE_SSL (default off) — Docker-interní Postgres
  # nemá TLS; nastav DATABASE_SSL=true pro managed/remote Postgres který ho vyžaduje.
  config :span_chain, SpanChain.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: System.get_env("DATABASE_SSL", "false") == "true"
end
