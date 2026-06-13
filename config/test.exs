import Config

# GF-704: Repo password comes from .env.test/.env via Dotenvy in config/runtime.exs.
# Dotenvy can't live here — compile-time config is evaluated before deps load.
config :span_chain, SpanChain.Repo,
  username: "postgres",
  hostname: "localhost",
  database: "span_chain_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :span_chain,
  http_port: 4002,
  start_http_server: false,
  # The Endpoint GenServer runs (needed for Phoenix.LiveViewTest), but `server: false`
  # in the endpoint config (below) ensures it does not bind a TCP socket. PubSub is a child
  # of the Endpoint supervisor → real-time /trail broadcast works in tests.
  start_phoenix_endpoint: true,
  start_broadway_pipeline: true,
  # The test env uses BufferProducer (the real producer) instead of DummyProducer:
  # SGS → BufferProducer → Pipeline → DB thus works end-to-end in tests.
  # Trade-off: Broadway.test_message/3 is unavailable (requires DummyProducer); negative
  # Pipeline tests must go through the real flow or BufferProducer.enqueue directly.
  broadway_producer_module: SpanChain.Ingestion.BufferProducer,
  broadway_batch_timeout_ms: 50,
  # GF-786: epoch_drain_timeout is NO LONGER a config key — derived from batch_timeout
  # in session_supervisor.ex (50*10+200=700ms in tests).
  # GF-782: drain-until-silence okno > test batch_timeout (50ms); prod default 200ms.
  epoch_drain_silence_ms: 75,
  # GF-779: tests run at concurrency: 1 (deterministic ordering without a partition
  # race). Prod/dev use the code defaults (schedulers_online / 4) from pipeline.ex.
  broadway_processor_concurrency: 1,
  broadway_batcher_concurrency: 1,
  # GF-648: negative-path tests need a fast retry — prod default is 500ms (1.5s total
  # worst-case with 3 attempts + exp backoff); in tests 1ms keeps runtime under ~50ms.
  broadway_retry_initial_delay_ms: 1,
  # GF-648: DI seams for Pipeline negative tests. Default = the real modules; per-test
  # override via Application.put_env + on_exit restore (see pipeline_negative_test.exs).
  ledger_module: SpanChain.Ledger,
  dead_letter_module: SpanChain.DeadLetter,
  # GF-807/805: ReplayJobSweeper starts in tests too, but auto-sweeps are effectively off
  # (huge intervals); tests call sweep_stuck_jobs/0 + sweep_retention/0 directly.
  # stuck_stale_threshold_s: 1 → a fresh "running" job (utc_now) survives, a stale one (2020) is swept.
  stuck_sweep_interval_ms: 999_999,
  retention_sweep_interval_ms: 999_999,
  stuck_stale_threshold_s: 1,
  # GF-788: LedgerVerifier starts but never auto-sweeps; tests call sweep_now/0 directly.
  verify_sweep_interval_ms: :infinity,
  verify_since_minutes: 1

config :span_chain, SpanChain.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: false

config :span_chain, :api_key, "test-secret"

# GF-766: throttle default-off in tests — avoids flaky failures from ETS timing.
# The rate-limit describe block enables it via Application.put_env in setup.
config :span_chain, :rate_limit_enabled, false

config :logger, level: :warning
