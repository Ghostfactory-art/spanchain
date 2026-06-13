# GhostFactory Observability — Architecture Map

> Living architectural reference covering all modules of the `span_chain`
> backend (L1 + L2 + L3 foundation; post Sprint 13). Module names, function
> signatures and line counts last reviewed 2026-06-13 (Postgres per GF-704;
> React/Vite frontend GF-792a; `span_id` + Evals compare GF-793; Evals/Cassettes
> React wiring GF-794; `replay_jobs.new_run_id` UNIQUE + 409 guard GF-832;
> OTLP per-group `with/else` GF-849; `/api` run_id validace GF-850;
> Trail run-list order_by `inserted_at` GF-855;
> Trail real-time polling GF-856; LedgerVerifier periodic sweep GF-788;
> OTLP compatibility matrix GF-973; TRAIL_AUTH_ENABLED gate GF-978).
> Citations from `@moduledoc` are marked with `›`.

---

## 1. Overview: What this system does

GhostFactory Observability is an **append-only audit-trail backend for AI agents**:
it receives OTLP-style spans over HTTP, computes for each span a SHA256 hash chained
to the previous one (hash-chain), persists them into the Postgres Ledger, and provides
a real-time read UI (`/trail`), structural comparison of runs (`/evals`), and
deterministic VCR replay (`/cassettes`). Layer L1 = the synchronous hash-chain
in the SessionGenServer; layer L2 = asynchronous persistence via the Broadway pipeline.
The client (Python/TS SDK) is dumb — the backend holds all the integrity and comparison logic.

---

## 2. Supervision tree — overview

Root `SpanChain.Supervisor` (`:one_for_one`) + sub-supervisor `PipelineSupervisor`
(`:rest_for_one`, GF-672) wrapping `[BufferRegistry, Pipeline]`. Per-node rationale,
restart strategy, and an OTP-for-Next.js mental model.

→ Detail: [`arch/supervision-and-otp.md`](arch/supervision-and-otp.md)

---

## 3. Data flow — end-to-end flow (overview)

HTTP POST `/ingest` → `AuthPlug` → `Ingestion.Router` → `SessionGenServer` (synchronous
in-memory hash) → `BufferProducer` → Broadway `Pipeline` (metadata upserts + `Ledger.insert_batch`)
→ Postgres + `Phoenix.PubSub` broadcast.

→ Detail: [`arch/data-flow.md`](arch/data-flow.md)

---

## 4. Module Dependency Matrix

| Module | Depends on | Depended on by |
|---|---|---|
| `SpanChain.Application` | all child specs | — (boot entry) |
| `SpanChain.Repo` | Ecto, postgrex (GF-704; formerly ecto_sqlite3) | Ledger, DeadLetter, Run, Eval, Cassette, Evals, Cassettes, TrailLive, EvalLive, Pipeline (via Repo.transaction + `ensure_run_records/1` + `ensure_eval_records/1` + `upsert_agent_configs/1` — GF-751/GF-746/GF-748), Harness (indirectly). **After GF-751** the SGS Repo dependency disappeared entirely. |
| `SpanChain.Ledger` | `Repo`, `PayloadSerializer`, `Ledger.Behaviour` | SGS, Pipeline, Cassettes, Cassettes.Replayer, Evals.Comparator, TrailLive, EvalLive (indirectly), Web.ApiController (GF-789), property tests, ledger_test. **Hash input** (GF-787): `compute_hash/7` = `seq:prev_hash:event_type:payload:parent_span_id:run_id:epoch_id` — `run_id`+`epoch_id` added to the hash, so an entry is cryptographically bound to its run/epoch (not just by the SQL filter in `verify_ledger`). **Projection columns** (GF-669 + GF-653 + GF-790): `span_id`, `trace_id`, `started_at`, `ended_at`, `status` — none of them are in the `compute_hash/7` input; `payload` stays the authoritative integrity source. **GF-790:** `status` populated in `build_entry` from `payload["status"]` (per-span status for waterfall error highlight) |
| `SpanChain.Ledger.Behaviour` | — | Ledger (implements), pipeline_negative_test stubs |
| `SpanChain.PayloadSerializer` | `Jason` | Ledger (canonical_encode), Harness (serialize_value) |
| `SpanChain.DeadLetter` | `Repo`, `Ecto.Changeset`, `Logger` | Pipeline (handle_failed), dead_letter_test |
| `SpanChain.Run` | `Eval` (belongs_to FK) | Pipeline (`ensure_run_records/1` + `upsert_agent_configs/1` — GF-751/GF-748), Evals (list_run_ids), Comparator (load_run) |
| `SpanChain.Eval` | `Run` (has_many) | Evals (create/get), Pipeline (`ensure_eval_records/1` — GF-746) |
| `SpanChain.Cassette` | `Ecto.Changeset` | Cassettes (record/get), Cassettes.Replayer |
| `SpanChain.Evals` | `Eval`, `Run`, `Repo`, `Evals.Comparator` | Evals.Router, Web.EvalLive |
| `SpanChain.Evals.Comparator` | `Ledger`, `Repo`, `Run` | Evals (defdelegate), Web.EvalLive, Cassettes.Replayer |
| `SpanChain.Evals.Router` | `Evals`, `Plug.Router` | Ingestion.Router (forward) |
| `SpanChain.Cassettes` | `Cassette`, `Ledger`, `Repo`, `Replayer`, `ReplayJob`, `Task.Supervisor` (GF-798) | Cassettes.Router, Web.ApiController (async replay), cassettes_test. **GF-798:** `enqueue_replay/2` (insert `ReplayJob` "running" → `Task.Supervisor.start_child(SpanChain.TaskSupervisor, run_replay_job)` → `{:ok, job}`), `run_replay_job/1` (reuse `replay/2`; `{:ok}`→completed / `{:error}`/rescue→failed), `get_replay_job/1` (non-bang, UUID-cast guarded). **GF-823:** `cancel_replay_job/1` (UUID-guarded; `pending`/`running`→`"cancelled"`, terminal→`:already_terminal`, unknown→`:not_found`) — backs `DELETE /api/cassettes/replay_jobs/:id`. **GF-828:** `get_replay_job_for_run/1` (read-only; direct `new_run_id` match — `:string` column, **not** UUID, no cast; `order_by inserted_at desc` + `limit 1` → `Repo.one` safe; `nil`/non-binary → `nil`) → backs the `ApiController.get_run` `replay_job` enrichment for the cancelled-replay banner. |
| `SpanChain.Cassettes.Replayer` | `Cassette`, `Ledger`, `Repo`, `Comparator`, `SessionSupervisor`, `SessionGenServer`, `Phoenix.PubSub` | Cassettes (replay), replayer_test. **Unchanged in GF-798** — a pure module, it just runs in the Task.Supervisor task process instead of the HTTP request process (the sync port-4000 `/cassettes/*` still calls it in the request process). |
| `SpanChain.Cassettes.ReplayJob` | `Ecto.Schema`, `Ecto.Changeset` | Cassettes (`enqueue_replay`/`get_replay_job`/`run_replay_job`/`cancel_replay_job`), Web.ApiController (polling + cancel). GF-798: `replay_jobs` table (uuid PK, jsonb `result`), state `running`→`completed`/`failed`. GF-823: `changeset/2` has `validate_inclusion(:status, [...])` incl. `"cancelled"` (cancel path). GF-827: the terminal write via `run_replay_job/1`→`finish_replay_job/3` is an atomic `Repo.update_all` with `WHERE status = "running"` (changeset helper `update_replay_job/2` removed) — a ghost Task can't overwrite a cancelled job. **GF-832:** migration `create unique_index(:replay_jobs, [:new_run_id])` (column `null: false`, fresh per job → a plain unique index is a full guarantee) + `changeset/2` `unique_constraint(:new_run_id)` → a DB violation comes back as `{:error, changeset}` (not a raised `Ecto.ConstraintError`). The DB-level last line of defense behind the `get_replay_job_for_run/1` `ORDER BY … LIMIT 1` safety net. |
| `SpanChain.Cassettes.ReplayJobSweeper` | `Repo`, `ReplayJob`, `Ecto.Query` | application.ex (root child, after TaskSupervisor). **GF-807/805:** a periodic GenServer with two sweeps — `sweep_stuck_jobs/0` (`update_all` stale `running` jobs `inserted_at < now - threshold` → `failed`/`%{"error"=>"timeout_or_killed"}`; catches `:EXIT` kills that the `run_replay_job/1` rescue doesn't) + `sweep_retention/0` (`delete_all` completed/failed older than 30 days). Both public for testing without a mount; intervals + threshold via config seams (`stuck_sweep_interval_ms`/`retention_sweep_interval_ms`/`stuck_stale_threshold_s`). |
| `SpanChain.LedgerVerifier` | `Ledger`, `Run`, `Repo`, `:telemetry`, `Logger` | `Application` (root child, after ReplayJobSweeper). GF-788: periodic GenServer — `sweep_now/0` public for testing; `do_sweep/0` queries recent `run_ids` via `Run` schema (limit 200, `DateTime` cutoff), calls `verify_ledger/1` per run; `:chain_broken` → `Logger.error` + `[:span_chain, :ledger, :chain_broken]` telemetry; unexpected errors → `Logger.warning`. Config seams: `:verify_sweep_interval_ms` (default 300_000; `:infinity` disables auto-sweep for tests), `:verify_since_minutes` (default 60). |
| `SpanChain.Cassettes.Router` | `Cassettes`, `Plug.Router` | Ingestion.Router (forward) |
| `SpanChain.Ingestion.Router` | `AuthPlug`, `RateLimiter`, `ValidationPlug`, `OtlpTranslator`, `SessionGenServer`, `SessionSupervisor`, `Evals.Router`, `Cassettes.Router`, `Plug.Router` | Bandit listener (Application). **GF-849:** `handle_otlp/1` iterates the span groups via `Enum.reduce` with a per-group `with/else` (mirrors `do_ingest/3`) — an `{:error, reason}` from `ensure_session`/`ingest_spans` is logged (`[OTLP] …`) + continues instead of a bare-match `MatchError → 500` (which dropped the remaining groups); status 200 + `partialSuccess` with an accurate `rejectedSpans`. |
| `SpanChain.Ingestion.AuthPlug` | `Plug.Conn`, `Plug.Crypto.secure_compare`, `Application.get_env` | Ingestion.Router |
| `SpanChain.Ingestion.RateLimiter` | `PlugAttack`, `Plug.Conn`, `Jason`, `PlugAttack.Storage.Ets` | Ingestion.Router (pipeline plug AFTER AuthPlug, BEFORE Plug.Parsers). GF-766: per-API-key throttle (Bearer token as the key, not IP — X-Forwarded-For is spoofable). Limit `:rate_limit_count`/`:rate_limit_period_ms` (default 1000/60s); over the limit → 429 `rate_limit_exceeded` + `Retry-After` via `block_action/3` + `halt()`. ETS storage worker (`PlugAttack.Storage.Ets`, name `SpanChain.Ingestion.RateLimiter`) in the Application supervision tree before the HTTP listener. Test seam: `:rate_limit_enabled` (false in `config/test.exs`) via the overridden `call/2`. **GF-785:** first rule `"allow health check"` (`if conn.request_path in ["/health","/health/"]` → `allow(true)`) — `/health` exempt from throttle (the LB health-check won't get a 429); nil for other paths → throttle unchanged. |
| `SpanChain.Ingestion.ValidationPlug` | `Plug.Conn`, `Jason`, `@valid_id_regex` | Ingestion.Router (pipeline plug after Plug.Parsers, before `:match`). GF-767: path-scoped to `request_path == "/ingest"` — sanitizes `run_id` (required) + `agent_id` (optional) with the regex `^[a-zA-Z0-9_-]{1,128}$`; malformed → 400 `invalid_id_format` + `halt()` before the data reaches the SGS. Other routes (`/health`, `/v1/traces`, `/evals`, `/cassettes`) pass through unchanged. **GF-774:** the public `valid_run_id?/1` (delegates to `valid_id?(_, :required)`, same `@valid_id_regex`) is called from `Router.handle_otlp` for the `/v1/traces` run_id (the plug `call/2` path-scope is unchanged). **GF-850:** `valid_run_id?/1` is also reused from `Web.ApiController` (:4001) — a single-source regex contract across both ports. |
| `SpanChain.Ingestion.OtlpTranslator` | (pure, no dependencies) | Ingestion.Router (handle_otlp) — `extract_run_id/1` (`service.instance.id`) + `extract_eval_id/1` (`gf.eval_id`) + `translate_span/1` emits a snake_case payload (`"span_id"`, `"trace_id"`, `"parent_span_id"`) → consumed by the Ledger.build_entry projections (GF-653 Scenario A audit) |
| `SpanChain.Ingestion.SessionSupervisor` | `SessionGenServer`, `SessionRegistry`, `DynamicSupervisor`, **GF-775 recovery:** `Repo`, `Ledger`, `Phoenix.PubSub` (`fetch_last_epoch`/`fetch_last_hash`/`await_epoch_drain` — the Repo read lives EXCLUSIVELY here, the SGS stays Repo-free). **GF-782:** `await_epoch_drain` → `drain_until_silence/3` (drains until `silence_ms` of silence, not just the first `{:epoch_flushed}`; seam `epoch_drain_silence_ms` 200ms/75ms — multi-batch `chain_broken` fix, ADR-003 closed). **GF-786:** `epoch_drain_timeout` is NOT a config key — derived as `broadway_batch_timeout_ms * 10 + 200` (tracks the runtime `BATCH_FLUSH_TIMEOUT_MS`; prod 1200ms / test 700ms) + `Logger.warning` on drain timeout | Ingestion.Router, Cassettes.Replayer, Harness, session_supervisor_test |
| `SpanChain.Ingestion.SessionGenServer` | `Ledger`, `BufferProducer`, `SessionRegistry` | SessionSupervisor (start_child), Ingestion.Router, Harness, Cassettes.Replayer, session_gen_server_test. **Public API:** `ingest_spans/2` (legacy) + `ingest_spans/3` (GF-727 late-binding via `opts[:eval_id]`); telemetry `[:gf, :sgs, :late_bind_eval_id]` fires max 1× per SGS lifetime. **After GF-751 (commit `9c7f03c`):** the SGS is a pure in-memory hash-chain with no DB dependencies (`Repo`/`Run`/`Eval`/`Ecto.Query` aliases removed); `:eval_id` is attached to entries in `append_span/2` as an in-memory sidecar (the Pipeline strips it before `Ledger.insert_batch`). **GF-775:** `restart: :temporary` (crash does NOT auto-restart → recovery via `ensure_session`); `start_link`/`init` accept `epoch_id`+`prev_hash` (spawn opts; the SGS is still Repo-free). |
| `SpanChain.Ingestion.BufferProducer` | `Broadway.NoopAcknowledger`, `BufferRegistry`, `GenStage` | SGS (enqueue), Pipeline (producer module via config), buffer_producer_test |
| `SpanChain.Ingestion.Pipeline` | `Broadway`, `BufferProducer` (via config), `Ledger` (via config), `DeadLetter` (via config), `Repo`, `Run`, `Ecto.Query`, `Phoenix.PubSub`, private `with_retry/3` | Application (child via PipelineSupervisor), pipeline_test, pipeline_negative_test. **Metadata phases** (`handle_batch/4`, GF-751/GF-746/GF-748): `ensure_run_records/1` → `ensure_eval_records/1` → `upsert_agent_configs/1` BEFORE `insert_batch`. Defensive rescue on each phase — a failure must not crash the pipeline or block the ledger insert. **GF-779:** processors `schedulers_online` / batcher 4 + `partition_by: :erlang.phash2(run_id)` (test env 1 via seams). **GF-775:** broadcast `{:epoch_flushed, run_id, epoch_id}` after commit (crash-recovery drain signal). **GF-777:** `batch_timeout` default 100ms (`config.exs`; the real 1000ms source was config.exs, not a pipeline hardcode; prod env var `BATCH_FLUSH_TIMEOUT_MS` in `runtime.exs`, guard `!= :test`). **GF-790:** `ensure_run_records/1` groups per `run_id` + derives `runs.started_at` as the oldest span `started_at` (`Enum.min` nil-safe) + an `on_conflict` LEAST upsert (query form; converges across batches, replaced `on_conflict: :nothing`). |
| `SpanChain.Ingestion.TelemetryLogger` | `:telemetry`, `Logger` | Application.start (attach), development.md |
| `SpanChain.Harness` | `SessionGenServer`, `SessionSupervisor`, `PayloadSerializer` | user Elixir code, harness_test |
| `SpanChain.Web.Endpoint` | `Phoenix.Endpoint`, `Bandit.PhoenixAdapter`, `Web.Router`, `PubSub` | Application |
| `SpanChain.Web.Router` | `Phoenix.Router`, `Web.TrailLive`, `Web.EvalLive`, `Web.ApiController` (GF-789), `Corsica`, `Ingestion.AuthPlug`, `Web.RateLimiter` (GF-851), `Web.Layouts`, `Web.TrailAuth` (GF-978) | Web.Endpoint |
| `SpanChain.Web.RateLimiter` (GF-851) | `PlugAttack`, `Plug.Conn`, `Jason`, `PlugAttack.Storage.Ets` | Web.Router (plug in `:api` AFTER AuthPlug + in `:browser` after `:accepts`), api_controller_test. Rate limiting for port 4001: `:api` per Bearer token (storage `Web.RateLimiter.Api`), public `/trail` per client IP (storage `Web.RateLimiter.Trail`). IP key from `x-forwarded-for` (Caddy adds the real client IP; fallback `conn.remote_ip` for local curl) — NOT the raw `remote_ip` (behind a proxy everyone would share one IP). Separate ETS tables → `/api` and `/trail` buckets are independent, no sharing with port 4000. Limits mirror 4000 via the same config keys (`:rate_limit_count`/`:rate_limit_period_ms`, default 1000/60s); over the limit → 429 `rate_limit_exceeded` + `Retry-After` via `block_action/3` + `halt()`. Test seam `:rate_limit_enabled` (false in `config/test.exs`) via the overridden `call/2`. Two ETS storage workers in the Application tree before the endpoint. XFF is spoofable — a more robust `Plug.RemoteIp` is Later (a new dependency). |
| `SpanChain.Web.TrailLive` | `Ledger`, `Repo`, `Phoenix.PubSub`, `Phoenix.LiveView` | Web.Router (live route), trail_live_test |
| `SpanChain.Web.EvalLive` | `Eval`, `Evals`, `Evals.Comparator`, `Phoenix.LiveView` | Web.Router (live route), eval_live_test |
| `SpanChain.Web.TrailAuth` | `Phoenix.LiveView` | `Web.Router` (live_session on_mount). GF-978: checks `:trail_authenticated` session flag; halts if flag absent and `:trail_auth_enabled` true; no-op when flag is false (default). |
| `SpanChain.Web.ApiController` (GF-789) | `Phoenix.Controller`, `Plug.Conn`, `Ecto.Query`, `Repo`, `Ledger`, `Evals`, `Cassettes` | Web.Router (`:api` scope), api_controller_test. Read-only JSON API under `/api` (port 4001): runs list/detail/span/verify, evals list/detail, cassettes list/replay. OOM-safe: list/skeleton only native columns (no `payload`/JSONB extraction), payload only in `get_span`; span/error counts grouped-count + `Map.new`. `:api` pipeline = Corsica (CORS, FIRST) → `:accepts json` → AuthPlug (Bearer reuse). Catch-all `options "/*path"` route so the OPTIONS preflight passes through the pipeline. **GF-828:** `get_run/2` returns a top-level `replay_job` field (`%{status: "cancelled"} | nil` via `Cassettes.get_replay_job_for_run/1`) — sibling to `run`/`spans`, feeds the cancelled-replay banner in the Dossier. **GF-832:** `replay_cassette/2` got a `{:error, %Ecto.Changeset{}}` clause → 409 `new_run_id_already_exists` (duplicate `new_run_id` from the `unique_constraint` — previously a dormant path → `CaseClauseError → 500`). **GF-850:** run_id format validation on :4001 (reuse `Ingestion.ValidationPlug.valid_run_id?/1`) — `plug :validate_run_id when action in [:get_run, :get_span, :verify_run]` → 400 `invalid_run_id` before the DB; `replay_cassette/2` inline guard on the user `new_run_id` before `enqueue_replay`. Closes GF-842b audit Finding F3. **GF-855:** `list_runs` orders by `order_by [desc: inserted_at]` (monotonic row-creation time), NOT the nullable/derived `started_at` (a null run floats up via NULLS FIRST, a stale-date run sinks down → the run looks "missing"); the select is extended with `inserted_at` for the Trail "Filed" field (FileCard/RegisterRow). |
| `SpanChain.Agent` (L0 ref) | — (isolated) | Orchestrator |
| `SpanChain.Orchestrator` (L0 ref) | `Agent`, `AgentSupervisor` | Application (root child) |
| `SpanChain.StressTest` | SGS / HTTP (load generator) | manual `mix run -e` invocation |
| `SpanChain.Release` (GF-783) | `Ecto.Migrator`, `Application` | OTP release boot (`entrypoint.sh` → `bin/span_chain eval "SpanChain.Release.migrate()"`); an infra-only migration helper for Docker self-hosting, no runtime consumer |
| `ghostfactory.attrs` (Python SDK) | `hashlib` (stdlib) | span_chain users; `gf.attrs.*` re-exported from `__init__.py`. Constants: `GEN_AI_*` (GF-735 OTel GenAI spec) + `GF_USAGE_COST_USD` + `GF_AGENT_*` (GF-738 GF extension) + `GF_REASONING_*` (GF-736 reasoning capture) + `GF_TASK_*` (GF-737 task delegation) + the `hash_prompt(text)` utility (SHA-256[:16] fingerprint). |
| `attrs` (TS SDK, `src/attrs.ts`) | `node:crypto` (Node builtin) | re-exported via `export * as attrs from "./attrs.js"` in `index.ts`. Same constants as Python (literal types via `as const`) — including `GF_REASONING_*` (GF-736) and `GF_TASK_*` (GF-737) — plus `hashPrompt(text)`. Cross-language hash parity pinned by a test (`hashPrompt("") === "e3b0c44298fc1c14"`). |

Acyclic check: no module depends on its downstream consumer.
Comparator/Cassettes depend on Ledger; Ledger does not depend on Comparator. The web layers
depend on the domains; the domains do not depend on the web. ✅

---

## 5. Hash-chain invariant — overview

hash-chain invariant: `compute_hash/7` (GF-787) cryptographically binds an entry to its
`run_id`+`epoch_id`; `verify_ledger/1`, `canonical_encode`, the epoch boundary, and the defense against
the "Epoch Island Attack". (lowercase `hash`)

→ Detail: [`arch/hash-chain.md`](arch/hash-chain.md)

---

## 6. Broadway — overview

Broadway async persistence: producer/consumer model, why `rest_for_one`, concurrency
(GF-779 post-Postgres GF-704), and retry semantics with DeadLetter routing.

→ Detail: [`arch/broadway-pipeline.md`](arch/broadway-pipeline.md)

---

## 7. Eval + Replay system — overview

Eval Framework (GF-706/707) + `Comparator` (pure tree diff) + VCR Cassettes/Replay
(GF-712) + the async replay job model (GF-798) + the web UI layers (Trail/Eval/Dossier).

→ Detail: [`arch/eval-and-replay.md`](arch/eval-and-replay.md)

---

## 8. Test architecture — overview

How we test OTP: `assert_receive` instead of `Process.sleep`, the Broadway telemetry barrier
pattern, `broadway_producer_module` config injection (not Mox), property tests (StreamData).

→ Detail: [`arch/testing-otp.md`](arch/testing-otp.md)

---

## 9. SDK contract — overview

SDK contract (Python + TypeScript): OTLP/HTTP JSON exporter, resource attribute keys
(`service.instance.id`, `gf.eval_id`), per-span value coercion (`intValue` / `boolValue` /
`doubleValue` / `stringValue`), and the `attrs` module with `gen_ai.*` (OTel GenAI spec) + `gf.agent.*`
GF extension constants (+ `hash_prompt`). The "SDK stays dumb" principle.

→ Detail: [`arch/sdk-contract.md`](arch/sdk-contract.md)

---

## 10. Open questions and known limitations — overview

Open questions, known limitations + known gaps (discrepancies vs the prompt task): the buffer is not
persistent, the L3 revision of `with_retry`/BufferRegistry, resolved paper-trails.

→ Detail: [`arch/open-questions.md`](arch/open-questions.md)

---

## Detailed sections (arch/)

The detailed prose of these sections was split into `arch/` (context refactor). The overview is above;
the §4 Dependency Matrix stays here in full.

- §2 [`arch/supervision-and-otp.md`](arch/supervision-and-otp.md)
- §3 [`arch/data-flow.md`](arch/data-flow.md)
- §5 [`arch/hash-chain.md`](arch/hash-chain.md)
- §6 [`arch/broadway-pipeline.md`](arch/broadway-pipeline.md)
- §7 [`arch/eval-and-replay.md`](arch/eval-and-replay.md)
- §8 [`arch/testing-otp.md`](arch/testing-otp.md)
- §9 [`arch/sdk-contract.md`](arch/sdk-contract.md)
- §10 [`arch/open-questions.md`](arch/open-questions.md)
