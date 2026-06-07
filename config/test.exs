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
  # Endpoint GenServer běží (potřeba pro Phoenix.LiveViewTest), ale `server: false`
  # v endpoint config (níže) zaručí, že nebindí TCP socket. PubSub je child
  # Endpoint supervisoru → real-time /trail broadcast funguje v testech.
  start_phoenix_endpoint: true,
  start_broadway_pipeline: true,
  # Test env používá BufferProducer (real producer) místo DummyProducer:
  # SGS → BufferProducer → Pipeline → DB tak funguje end-to-end v testech.
  # Trade-off: Broadway.test_message/3 nelze (vyžaduje DummyProducer); negativní
  # testy Pipeline musí jít přes real flow nebo direkt BufferProducer.enqueue.
  broadway_producer_module: SpanChain.Ingestion.BufferProducer,
  broadway_batch_timeout_ms: 50,
  # GF-786: epoch_drain_timeout už NENÍ config key — derivováno z batch_timeout
  # v session_supervisor.ex (50*10+200=700ms v testech).
  # GF-782: drain-until-silence okno > test batch_timeout (50ms); prod default 200ms.
  epoch_drain_silence_ms: 75,
  # GF-779: testy běží na concurrency: 1 (deterministické ordering bez partition
  # race). Prod/dev používají code defaults (schedulers_online / 4) z pipeline.ex.
  broadway_processor_concurrency: 1,
  broadway_batcher_concurrency: 1,
  # GF-648: negative-path testy potřebují rychlý retry — prod default je 500ms (1.5s total
  # worst-case s 3 attempts + exp backoff); v testech 1ms drží runtime pod ~50ms.
  broadway_retry_initial_delay_ms: 1,
  # GF-648: DI seamy pro Pipeline negative tests. Default = reálné moduly; per-test
  # override přes Application.put_env + on_exit restore (viz pipeline_negative_test.exs).
  ledger_module: SpanChain.Ledger,
  dead_letter_module: SpanChain.DeadLetter,
  # GF-807/805: ReplayJobSweeper startuje i v testech, ale auto-sweepy fakticky vypnuty
  # (obří intervaly); testy volají sweep_stuck_jobs/0 + sweep_retention/0 přímo.
  # stuck_stale_threshold_s: 1 → čerstvý "running" job (utc_now) zůstane, stale (2020) padne.
  stuck_sweep_interval_ms: 999_999,
  retention_sweep_interval_ms: 999_999,
  stuck_stale_threshold_s: 1

config :span_chain, SpanChain.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: false

config :span_chain, :api_key, "test-secret"

# GF-766: throttle default-off v testech — vyhne se flaky failům z ETS timingu.
# Rate-limit describe blok ho zapne přes Application.put_env v setup.
config :span_chain, :rate_limit_enabled, false

config :logger, level: :warning
