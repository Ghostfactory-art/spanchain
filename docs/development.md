# Development Guide

This document is for engineers working on the GhostFactory backend itself (the `gf_experiment` codebase). For consumer-side documentation, see the project [README](../README.md).

---

## Setup

Prerequisites: **Elixir 1.19+** (with Erlang/OTP 27 or 28), **PostgreSQL 16+** (GF-704 — the Repo runs on `Ecto.Adapters.Postgres`; connection params come from `config/dev.exs` + `.env`, see `.env.example`), and **Node.js 18+** for the Vite asset build (GF-792a).

```bash
mix deps.get
mix ecto.create        # Postgres @ localhost:5432 (PGPASSWORD via .env)
mix ecto.migrate
mix test               # confirm the suite is green before doing anything else
mix run --no-halt      # start the HTTP server on :4000

cd assets && npm install   # React frontend deps
cd assets && npm run build # build → priv/static/app.js + app.css
```

On Windows, paths and PowerShell quoting differ slightly; the commands above run unchanged under Git Bash or WSL. The bandit listener binds to `0.0.0.0:4000` by default; override with the `:http_port` config key in `config/dev.exs`.

The `mix test` alias defined in `mix.exs` runs `ecto.create --quiet`, `ecto.migrate --quiet`, then `test`, so a clean checkout can run tests in one command.

---

## Smoke test the running server

```bash
curl -X POST http://localhost:4000/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "run_id": "dev-smoke-1",
    "spans": [
      {
        "span_id": "s1",
        "name": "llm_call",
        "started_at": "2026-05-16T10:00:00Z",
        "ended_at": "2026-05-16T10:00:01Z",
        "parent_span_id": null,
        "attributes": {"model": "claude-sonnet-4-6"}
      }
    ]
  }'
```

Expected response: `HTTP/1.1 202 Accepted` with body `{"run_id":"dev-smoke-1","accepted":1}`.

Inspect the row that was written:

```bash
mix run -e 'SpanChain.Ledger |> SpanChain.Repo.all() |> IO.inspect()'
```

(Stop the server first if it is still running — `mix run` boots a second instance and will fail to bind port 4000.)

---

## Adding a new event_type

The backend does not have per-event-type code paths — `event_type` is just a string discriminator on the Ledger row, and `payload` is an opaque `:map`. Adding a new event type is a contract change, not a code change.

1. **Define the schema** in [`docs/payload-schemas.md`](payload-schemas.md). List required fields, optional fields, types, and one realistic JSON example.
2. **Ship the SDK update.** The Python/TS SDK sends spans where `name` becomes the `event_type`. Make sure the SDK serializes the payload in the shape you documented.
3. **Write a test.** Add a case to `test/span_chain/ledger_test.exs` (or a new file under `test/span_chain/`) that posts a span with the new `event_type`, asserts the row lands in the DB, and asserts `Ledger.verify_ledger/1` returns `{:ok, :valid}`.

If a new event type needs **backend logic** (e.g. routing, derived columns, fan-out), that is a larger change and warrants its own ADR.

---

## Verifying the hash chain

`Ledger.verify_ledger/1` recomputes the hash of every entry for a given `run_id` and compares it against the stored hash. It returns `{:ok, :valid}`, `{:ok, :empty}`, or `{:error, :chain_broken}`.

```elixir
iex> SpanChain.Ledger.verify_ledger("dev-smoke-1")
{:ok, :valid}

iex> SpanChain.Ledger.verify_ledger("does-not-exist")
{:ok, :empty}
```

To see verification fail on purpose, tamper with a row directly:

```elixir
iex> import Ecto.Query
iex> alias SpanChain.{Ledger, Repo}
iex> Repo.update_all(from(l in Ledger, where: l.run_id == "dev-smoke-1" and l.seq == 0),
...>   set: [parent_span_id: "tampered"])
{1, nil}
iex> Ledger.verify_ledger("dev-smoke-1")
{:error, :chain_broken}
```

The chain breaks because `parent_span_id` is part of the hash input; see [ADR-001 §4](adr/001-architecture-decisions.md).

**GF-787:** `compute_hash/7` also includes `run_id` and `epoch_id` in the hash input
(`seq:prev_hash:event_type:payload:parent_span_id:run_id:epoch_id`), so relabeling a row's
`run_id`/`epoch_id` directly in the DB (moving an entry to another run/epoch) likewise yields
`{:error, :chain_broken}` — the entry is now bound to its run/epoch cryptographically, not only by
the `WHERE run_id` filter. (Scope note: the hash is still *unkeyed* SHA-256, so an attacker with DB
write access who recomputes the whole chain can still forge a clean ledger, and tail-truncation is
undetectable — keyed/HMAC + external anchoring would be the real tamper-evidence step.)

### Upgrading across GF-787 (hash format change)

Rows written **before GF-787** (commit `d87a4e5`) were hashed with the old `compute_hash/5`
input, which did **not** include `run_id`/`epoch_id`. GF-787 changed the hash input shape to
`seq:prev_hash:event_type:payload:parent_span_id:run_id:epoch_id`, so `verify_ledger/1` over
pre-GF-787 data recomputes a different hash than the one stored and returns
`{:error, :chain_broken}`. This is an **expected** format mismatch on stale data, not corruption.

**Dev DB — reset (drops all data):**

```bash
mix ecto.drop && mix ecto.create && mix ecto.migrate   # bash
```
```powershell
mix ecto.drop; mix ecto.create; mix ecto.migrate       # PowerShell/Windows
```

`mix ecto.reset` is **not** a defined alias in this project (see `mix.exs`); use the three
commands above. **Production:** see GF-783 (migration guide — TBD).

---

## Telemetry events (self-monitoring)

The backend emits `:telemetry` events under the `[:gf, ...]` namespace. These are for monitoring the **GhostFactory backend itself** — not for emitting customer span data. (See [ADR-001 §8](adr/001-architecture-decisions.md) for the rationale.)

```text
[:gf, :ingest,  :request,      :start | :stop | :exception]
[:gf, :session, :spawn,        :start | :stop | :exception]
[:gf, :ledger,  :batch_insert, :start | :stop | :exception]
[:gf, :epoch,   :boundary]
```

Measurement and metadata shapes:

| Event | Measurements | Metadata |
|---|---|---|
| `[:gf, :ingest, :request, :stop]` | `duration`, `monotonic_time` | `run_id`, `span_count`, `status` |
| `[:gf, :session, :spawn, :stop]` | `duration`, `monotonic_time` | `run_id`, `pid_str`, `reused` |
| `[:gf, :ledger, :batch_insert, :stop]` | `count`, `inserted`, `duration` | `{}` |
| `[:gf, :epoch, :boundary]` | `count: 1` | `run_id`, `from_epoch`, `to_epoch` |

Attach the bundled debug logger in dev when you want to see every event:

```elixir
iex> SpanChain.Ingestion.TelemetryLogger.attach()
:ok
```

The logger uses the same handler ID across calls, so re-attaching is idempotent. Detach with `SpanChain.Ingestion.TelemetryLogger.detach/0`.

---

## Project layout

```
gf_experiment/
├── config/                  — Mix config per env (dev, test, prod)
├── lib/span_chain/
│   ├── application.ex       — supervision tree boot
│   ├── repo.ex              — Ecto Postgres repo (GF-704)
│   ├── ledger.ex            — schema, compute_hash, build_entry, verify_ledger
│   ├── ingestion/
│   │   ├── router.ex        — Plug.Router for POST /ingest, GET /health
│   │   ├── session_gen_server.ex   — per-run_id stateful process
│   │   ├── session_supervisor.ex   — DynamicSupervisor + ensure_session race-safety
│   │   └── telemetry_logger.ex     — optional debug handler
│   ├── agent.ex             — L0 in-memory agent (reference impl, do not modify)
│   ├── orchestrator.ex      — L0 orchestrator (reference impl, do not modify)
│   └── span_chain.ex     — root module
├── priv/repo/migrations/    — Ecto migrations
├── test/                    — ExUnit tests
├── docs/                    — this directory
└── logs/session.log         — append-only task log (see CLAUDE.md)
```

---

## Dead-letter

If `Ledger.insert_batch/1` fails 3 times in a row inside a `SessionGenServer`
flush (exponential backoff 500/1000/2000 ms), the batch is persisted to the
`dead_letter_entries` table instead of being silently dropped. The hash chain
in the Ledger keeps advancing as if the insert succeeded — `verify_ledger/1`
on the affected `run_id` will report `{:error, :chain_broken}` because rows
are missing, which is the intended audit signal: "data exists, but not in
the authoritative source."

```elixir
# List unresolved dead-letter entries
iex> SpanChain.DeadLetter.list_unresolved()
[%SpanChain.DeadLetter{id: 1, run_id: "abc", error_reason: "...", resolved: false, ...}, ...]

# Mark a dead-letter entry as resolved (e.g. after manual reprocessing)
iex> SpanChain.DeadLetter.resolve(1)
{:ok, %SpanChain.DeadLetter{resolved: true, resolved_at: ~U[...]}}
```

The `:telemetry` event `[:gf, :flush, :dead_letter]` fires when this happens,
with measurements `%{count: N}` and metadata `%{run_id, reason}`. The bundled
`TelemetryLogger` routes this event to `Logger.error/1` so it is visible in
production logs without further configuration.

`DeadLetter.store/3` is itself defensive: if the dead-letter write also
fails, it logs and returns `{:error, reason}` rather than crashing the
`SessionGenServer` that called it. The safety net never takes the caller
down with it.

---

## Resolved L1 limitations (Sprint 2)

These were tracked tradeoffs that have since been fixed. Kept here as a paper trail.

- ✅ **Payload encoding is not canonical** — fixed in **GF-654**. `Ledger.compute_hash/5`
  now serializes payload via `SpanChain.PayloadSerializer.canonical_encode/1`
  (recursive lex-sorted JSON string built over sorted 2-tuples). Map key order
  jitter from HAMT (>32 keys) no longer causes false `{:error, :chain_broken}`.
- ✅ **Cast ordering across concurrent POSTs** — fixed in **GF-644**. `ingest_spans/2`
  is `GenServer.call` (was `cast`); concurrent callers serialize through the
  SGS mailbox, each POST atomic.
- ✅ **No DB-insert retry** — fixed in **GF-645** (initially in SGS) and refactored
  in **GF-667** (moved into `Pipeline.handle_batch` private `with_retry/3`,
  3 attempts with exp backoff 500/1000/2000 ms). Exhausted batches go to
  `DeadLetter.store/3` via `handle_failed/2`.
- ✅ **No authentication on `/ingest`** — fixed in **GF-646**. `SpanChain.Ingestion.AuthPlug`
  enforces `Authorization: Bearer <token>` via `Plug.Crypto.secure_compare` (timing-safe).
  `/health` is bypassed. Fail-closed `is_binary` guard if `:api_key` config is `nil`.
- ✅ **No rate limiting on `/ingest`** — added in **GF-766**. `SpanChain.Ingestion.RateLimiter`
  (`plug_attack`) throttles per API key (Bearer token), `429` + `Retry-After` over the limit.
  Pipeline: `AuthPlug → RateLimiter → Plug.Parsers → ValidationPlug → match`.
  **Tokenless behaviour (GF-785):** the throttle rule's `_ -> allow(true)` fallback means requests
  without a Bearer header are always allowed — throttling only applies to token-bearing requests.
  `/health` is additionally exempt via a first `allow` rule (GF-785); its exempt tests must send a
  Bearer token, since a tokenless `/health` test would pass even without the exempt rule.
- ✅ **No input validation on `/ingest`** — added in **GF-767**. `ValidationPlug` rejects
  malformed `run_id`/`agent_id` (regex `^[a-zA-Z0-9_-]{1,128}$`) with `400` before SGS.
- ✅ **No rate limiting on Phoenix port 4001** — added in **GF-851**. `SpanChain.Web.RateLimiter`
  (`plug_attack`, reuses the existing dep — no new dependency) throttles both port-4001 pipelines,
  `429` + `Retry-After` over the limit (mirrors the port-4000 `block_action/3`).
  - **`:api`** (`/api/*`, Bearer-gated) — per **token**, plug placed **after** `AuthPlug`
    (unauthorized stays `401`, not `429`). Storage table `Web.RateLimiter.Api`.
  - **`:browser`** (`/trail`, public, no token) — per **client IP**, plug after `:accepts`.
    Storage table `Web.RateLimiter.Trail`.
  - **Separate ETS tables** keep the `/api` and `/trail` buckets independent (a `/trail` flood
    can't exhaust the `/api` budget) and independent from the port-4000 bucket. Limits mirror
    port 4000 via the shared `:rate_limit_count` / `:rate_limit_period_ms` config (default
    `1000` / `60_000 ms`). Test seam: `:rate_limit_enabled` (`false` in `config/test.exs`).
  - **Client IP** is read from `x-forwarded-for` (Caddy adds the real client IP), falling back to
    `conn.remote_ip` for local/direct requests. We do **not** key on raw `conn.remote_ip`: behind
    the Caddy proxy that is the proxy's IP, so every visitor would share one bucket (the first
    burst would lock everyone out). **Caveat:** XFF is client-spoofable; `Plug.RemoteIp` (with
    trusted-proxy config) is the more robust solution — deferred (Later) because it needs a new
    dependency, which GF-851 forbids.

## Open L2 limitations

- **Buffer is not persistent.** `BufferProducer` is in-memory `:queue`. A crash
  loses in-flight entries that left SGS but had not yet been batched. L3 will
  swap for a persistent queue (NATS JetStream — GF-648 / GF-650 region).
- **SGS crash recovery — resolved (GF-775).** SGS is now `restart: :temporary`; the next ingest's
  `SessionSupervisor.ensure_session/1` recovers via epoch rollover + `prev_hash` carried from the DB
  (SGS stays Repo-free, GF-751; `verify_ledger` unchanged, GF-666 cross-epoch continuity preserved).
  ADR-003 IMPLEMENTED. The drain now **drains until silence** (GF-782): after the first
  `{:epoch_flushed}` it keeps consuming until `epoch_drain_silence_ms` of quiet (default 200ms =
  2× the 100ms prod `batch_timeout`; 75ms in test), so a burst spanning *multiple* in-flight
  batches can no longer leave the new epoch on a stale `prev_hash` → the old multi-batch
  `:chain_broken` residual is closed. The outer `epoch_drain_timeout_ms` (1_200ms) stays as the
  cold/fast-path guard. A crashed run's in-memory cursor stays down until its next span.
- **Postgres (GF-704) + concurrency unlocked (GF-779).** Repo runs on Postgres (`postgrex`); the
  former SQLite single-writer `concurrency: 1` is lifted — processors `System.schedulers_online()`,
  batcher `concurrency: 4` + `partition_by: :erlang.phash2(run_id)` (per-session serialization,
  cross-session parallelism on MVCC; producer stays 1). `with_retry/3` = Scénář B (blanket retry,
  covers Postgres transients). First Postgres baseline: `docs/stress-test-results-2026-05-27.md`.
- **OTLP run_id validation (GF-774).** `/v1/traces` validates `run_id` (from `service.instance.id`)
  with the same regex as `/ingest` via `ValidationPlug.valid_run_id?/1` → 400 `invalid_id_format`
  for malformed ids (previously bypassed the path-scoped plug).

### Resolved this session

- ✅ **GF-702** (commit `1bb49eb`): `:persistent_term` → `Agent` v negative test stubs.
- ✅ **GF-705** (commit `3e904d1`): Broadway sandbox contamination fix — `router_test`
  + `session_gen_server_test` čekají na flush před koncem testu (telemetry barrier).
  Pozdější Sprint 4 cleanup (`edc8c02`, `ed450b2`) převedl telemetry na
  post-commit PubSub po GF-703 změně, viz CLAUDE.md L#94.
- ✅ **GF-649** (commit `ab4c763`): OTLP/HTTP JSON endpoint `/v1/traces`. Protobuf
  variant zůstává L3.
- ✅ **GF-706** (commit `0fd366d`): Eval Framework backend — `evals` tabulka +
  `Comparator` + `/evals/*` HTTP API. Pasivní associace přes OTLP
  `resource.attributes["gf.eval_id"]`.
- ✅ **GF-703** (commit `6306083`): PubSub broadcast vs DB visibility — Option A
  (`Repo.transaction` wrap kolem `Ledger.insert_batch`). Broadcast až po commitu;
  WAL readery vidí data v okamžiku doručení broadcastu.
- ✅ **GF-712** (commit `eefc177`): Debug Replay Cassette backend — schema +
  context + pure Replayer + sub-router `/cassettes/*`. Replay přes normální
  SGS→Pipeline→Ledger; hash chain invariant zachován.
- ✅ **GF-672** (commit `75f7870`): `rest_for_one` sub-supervisor
  `PipelineSupervisor` obaluje `[BufferRegistry, Pipeline]`. Registry crash
  nyní správně cascade restart Pipeline → Broadway respawn BufferProducer →
  re-register `:singleton`. Scope shift od prompt-uvedeného wrap
  `[BufferProducer, Pipeline]` (ten by recreate GF-667 double-instance bug).
  Viz nová sekce "Supervision tree" níže.
- ✅ **GF-707** (commit `d9935a2`): `SpanChain.Web.EvalLive` LiveView na
  `/eval/:eval_id` — side-by-side diff UI nad `Evals.Comparator.compare/2`.
  První konzument Comparator z UI vrstvy (do teď jen JSON přes
  `GET /evals/:eval_id/compare`). Viz nová sekce "Eval UI" níže.

---

## Broadway Pipeline (post GF-667) — dev ops

Ingestion is asynchronous — `SessionGenServer` responds to HTTP immediately
(hash computation only), the DB write runs through a Broadway pipeline on the
side.

> **Architektura** (producer/consumer model, pipeline flow diagram, `rest_for_one`,
> concurrency GF-779, retry sémantika) → viz
> [`docs/arch/broadway-pipeline.md`](arch/broadway-pipeline.md). Níže jen dev/ops:
> config keys, `.env` loading, runtime introspekce.

Config keys (`config/config.exs` defaults):

```elixir
config :span_chain,
  broadway_producer_module: SpanChain.Ingestion.BufferProducer,
  broadway_batch_timeout_ms: 100,   # GF-777 (was 1_000); prod tunable via BATCH_FLUSH_TIMEOUT_MS (runtime.exs)
  start_broadway_pipeline: true   # gated, can be off in test/CI
```

`config/test.exs` keeps `BufferProducer` as the producer (real end-to-end flow
through SGS → BufferProducer → Pipeline → DB works in tests) but overrides
`broadway_batch_timeout_ms: 50` (below the 100ms prod default) so integration
tests flush fast.

**Local env (`.env`) loading (GF-704).** In `:dev`/`:test`, `config/runtime.exs`
loads `.env` via Dotenvy (`{:dotenvy, "~> 0.8", only: [:dev, :test]}`): the Repo
password reads `PGPASSWORD`, and `BATCH_FLUSH_TIMEOUT_MS` overrides `batch_timeout`
in non-test envs. Dotenvy lives in `runtime.exs`, not compile-time config (which
`Config.Reader` evaluates before deps are on the code path). `.env` is gitignored;
see `.env.example`.

Inspecting the pipeline at runtime:

```elixir
# Find the BufferProducer pid via Registry (singleton)
iex> [{pid, _}] = Registry.lookup(SpanChain.Ingestion.BufferRegistry, :singleton)
iex> :sys.get_state(pid).state
# → %{queue: <0..(40160 bytes)>, demand: 10}

# Failed batches after retry exhaustion live in dead_letter_entries
iex> SpanChain.DeadLetter.list_unresolved()
[%SpanChain.DeadLetter{id: 1, run_id: "abc", error_reason: "...", resolved: false, ...}]
```

Ordering invariant: Erlang FIFO between SGS and BufferProducer + `:queue.in/out`
FIFO + Broadway `processors: concurrency: 1` and `batchers: concurrency: 1`
together give a single deterministic serial order from POST to DB row. (Once we
move to Postgres in L3, processors concurrency can grow with
`partition_by: &(&1.data.run_id)` for per-run parallelism.)

---

## Supervision tree — dev ops

> **Architektura** (kompletní strom, per-node rationale, `PipelineSupervisor`
> `rest_for_one`/GF-672, OTP mentální model) → viz
> [`docs/arch/supervision-and-otp.md`](arch/supervision-and-otp.md). Níže jen
> operační smoke testy + známý edge case.

### Smoke test — supervision tree

```elixir
iex> Supervisor.which_children(SpanChain.Supervisor)
# zde uvidíš PipelineSupervisor jako child (ne BufferRegistry + Pipeline samostatně)

iex> Supervisor.which_children(SpanChain.Ingestion.PipelineSupervisor)
# → [{Registry, _, :supervisor, _}, {SpanChain.Ingestion.Pipeline, _, :supervisor, _}]

# Ověř re-registration po Pipeline crash (Broadway respawn producer):
iex> [{old_producer, _}] = Registry.lookup(SpanChain.Ingestion.BufferRegistry, :singleton)
iex> pipeline = Process.whereis(SpanChain.Ingestion.Pipeline)
iex> Process.exit(pipeline, :kill)
iex> :timer.sleep(200)
iex> [{new_producer, _}] = Registry.lookup(SpanChain.Ingestion.BufferRegistry, :singleton)
iex> new_producer != old_producer   # → true ✅ fresh BufferProducer re-registrl
```

Pozor: NE kill přímo na `BufferRegistry` supervisor — viz "Known edge case
(GF-724)" níže. Pipeline crash je čistý demo `rest_for_one` mechanismu bez
ETS race; demonstruje že Broadway-interni BufferProducer.init/1 se po
restart correctly re-registruje v stále živé Registry.

### Known edge case (GF-724 — Working as Intended)

`Process.exit(reg, :kill)` na celý `BufferRegistry` supervisor způsobí pád
aplikace. Příčina: BEAM asynchronně uvolňuje ETS jména partition procesů
po killu. `rest_for_one` spustí restart ihned — ale jména ještě nejsou
volná → `name already taken` → 3 okamžitá selhání → `max_restarts: 3`
vyčerpán → `PipelineSupervisor` padá → cascade do root supervisoru →
`Application exited: shutdown`.

Toto je BEAM expected behavior při `:kill` signálu na supervisor (fail-fast
princip). V produkci `Registry` jako celek nespadne — individual partitions
crashují izolovaně a self-restartují uvnitř Registry supervisoru bez
externího zásahu.

`:kill` na Registry supervisor je syntetický test, ne realistický produkční
failure mode. Diagnóza potvrzena Gemini + Grok review 2026-05-18 (s
nesouhlasem: Gemini uzavřel jako WaI, Grok doporučil fix pro L3). L3
followup: **GF-729** (BufferRegistry permanent supervisor výše v
hierarchii).

---

## Eval Framework (`/evals/*`)

`Eval` je zastřešující agregát pro porovnávání více `runs` se stejným záměrem
("stejná otázka, 3 různé modely"). Klient generuje `eval_id` a posílá ho jako
OTLP `resource.attributes["gf.eval_id"]`; backend pasivně upsertuje associaci
v `SessionGenServer.init/1`. Backend **neorchestruje** spuštění agentů.

### HTTP API

```
POST   /evals                              # vytvoří Eval
GET    /evals/:eval_id                     # detail s run_count + run_ids
GET    /evals/:eval_id/compare?run_a&run_b # strukturální + duration diff
```

Auth: `Authorization: Bearer <token>` (AuthPlug platí přes `forward "/evals"`).

```bash
# Vytvořit Eval
curl -X POST http://localhost:4000/evals \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"eval_id":"eval-llm-v1","name":"LLM comparison"}'
# → 201 {"eval_id":"eval-llm-v1","name":"LLM comparison","status":"running","created_at":"..."}

# Run pod evalem (OTLP s gf.eval_id attribute)
curl -X POST http://localhost:4000/v1/traces \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{"attributes":[
       {"key":"service.instance.id","value":{"stringValue":"run-a"}},
       {"key":"gf.eval_id","value":{"stringValue":"eval-llm-v1"}}
    ]},"scopeSpans":[{"spans":[...]}]}]}'

# Compare dvou runů
curl "http://localhost:4000/evals/eval-llm-v1/compare?run_a=run-a&run_b=run-b" \
  -H "Authorization: Bearer dev-secret-change-me"
# → 200 {"summary":{...},"differences":[{"span_name":...,"type":"duration_diff"|"span_added"|"span_removed","deviation_point":true},...]}
```

### Comparator semantics

`SpanChain.Evals.Comparator` je pure tree diff (žádný GenServer, žádný stav):

- Stromy spans sestaveny z `parent_span_id` hierarchie (stejný algoritmus
  jako `TrailLive.build_tree`)
- Children páruje podle `name` + sibling pozice (i-tý "llm_call" v A se matchuje
  s i-tým v B)
- Diff typy:
  - `span_added` — uzel v B který nemá pár v A
  - `span_removed` — uzel v A bez páru v B
  - `duration_diff` — spárované uzly s >20% rozdílem v `duration_ms`
- `deviation_point: true` — první emitovaný diff per top-level branch
- `{:error, :different_eval}` — pokud oba runs mají non-nil `eval_id` a liší se
- `{:error, :run_not_found}` — chybějící Run řádek

### Architecture

→ viz [`docs/arch/eval-and-replay.md`](arch/eval-and-replay.md) (Eval Framework,
`Comparator` pure tree diff, pasivní asociace `eval_id` přes SGS sidecar →
Pipeline metadata fáze, `duration_ms` payload-first).

---

## Eval UI (`/eval/:eval_id`)

`SpanChain.Web.EvalLive` (GF-707) je první konzument
`Evals.Comparator.compare/2` z UI vrstvy. Read-only, one-shot load —
žádný PubSub subscribe, žádný real-time refresh (na rozdíl od TrailLive).
URL query params jsou source of truth, takže view je linkable.

**Route:** `http://localhost:4001/eval/:eval_id` (Phoenix Endpoint port
4001 — stejný jako `/trail`).

### Tři views (pattern match na `:view` socket assign)

| `:view`   | Kdy                                                    | Co se renderuje                              |
|-----------|--------------------------------------------------------|----------------------------------------------|
| `:select` | `eval_id` resolved, žádné `run_a`/`run_b` query params | Dva `<select>` dropdowny + Compare submit    |
| `:diff`   | `run_a` + `run_b` v params, Comparator `{:ok, _}`      | Summary + diff table (nebo "Identical runs") |
| `:error`  | Eval neexistuje, `:run_not_found`, `:different_eval`   | Error message + Back link                    |

### Asociace `run` ↔ `eval`

EvalLive nezakládá runs — to dělá ingest cesta. Aby se run přiřadil k evalu,
klient v OTLP requestu nastaví `resource.attributes["gf.eval_id"]`:

```bash
curl -X POST http://localhost:4000/v1/traces \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{"attributes":[
       {"key":"service.instance.id","value":{"stringValue":"run-fast"}},
       {"key":"gf.eval_id","value":{"stringValue":"eval-llm-v1"}}
    ]},"scopeSpans":[{"spans":[{"name":"llm_call","traceId":"a","spanId":"1",
       "startTimeUnixNano":"1716000000000000000",
       "endTimeUnixNano":"1716000000100000000","attributes":[]}]}]}]}'
```

Backend pasivně upsertuje `%Eval{}` + nastaví `runs.eval_id` v SGS init
(viz Eval Framework sekce). Pak je run dohledatelný v `eval.runs` a
EvalLive `:select` view ho nabídne v dropdownu.

### Smoke test — Eval UI (IEx variant)

Pro rychlý UI test bez ingest cesty (přímo Repo + Ledger):

```elixir
# 1. Start: iex -S mix phx.server
iex> alias SpanChain.{Eval, Run, Repo, Ledger}

# 2. Vytvoř eval + dva runs
iex> eval_id = "eval-demo-1"
iex> Repo.insert!(%Eval{eval_id: eval_id, status: "running", name: "Demo"})
iex> Repo.insert!(%Run{run_id: "run-fast", status: "completed", eval_id: eval_id})
iex> Repo.insert!(%Run{run_id: "run-slow", status: "completed", eval_id: eval_id})

# 3. Vlož spans s ms-precision started_at/ended_at v payloadu (kvuli
#    sub-second duration_ms — GF-669 projekce truncuje na :second)
iex> mkspan = fn run_id, name, ms ->
...>   base = ~U[2026-05-18 10:00:00.000Z]
...>   payload = %{
...>     "span_id" => "s-#{run_id}",
...>     "started_at" => DateTime.to_iso8601(base),
...>     "ended_at" => DateTime.to_iso8601(DateTime.add(base, ms, :millisecond))
...>   }
...>   Ledger.build_entry(run_id, 0, 0, nil, name, payload, nil)
...> end
iex> Ledger.insert_batch([mkspan.("run-fast", "llm_call", 100)])
iex> Ledger.insert_batch([mkspan.("run-slow", "llm_call", 500)])
```

**Browser checkpoints:**

| URL                                                                            | Co uvidíš                                                      |
|--------------------------------------------------------------------------------|----------------------------------------------------------------|
| `http://localhost:4001/eval/eval-demo-1`                                        | `:select` view — dva dropdowny, `run-fast`/`run-slow`           |
| `http://localhost:4001/eval/eval-demo-1?run_a=run-fast&run_b=run-slow`          | `:diff` view — 100ms vs 500ms, **400% Δ**, ⚠ deviation marker  |
| `http://localhost:4001/eval/eval-demo-1?run_a=run-fast&run_b=run-fast`          | "✓ Identical runs — no differences detected"                    |
| `http://localhost:4001/eval/does-not-exist`                                     | `:error` view, "Eval not found"                                 |

### Architecture

- Comparator volán **přímo** (`alias SpanChain.Evals.Comparator`), ne
  přes `GET /evals/:id/compare` HTTP — jsme ve stejné OTP aplikaci, HTTP
  hop by byl zbytečný.
- `handle_event("compare", ...)` → `push_patch` na `/eval/:id?run_a=X&run_b=Y`
  → `handle_params/3` re-fires Comparator. URL state je single source of
  truth; refresh stránky vrátí identický view.
- `deviation_point` post-GF-740 (Sprint 7) označuje **první diff entry v každé
  top-level větvi** span stromu (ne globální index 0 jako pre-fix). UI
  vykresluje ⚠ marker per větev — agent s 5 souběžnými tool calls a 2
  divergentními větvemi zobrazí 2 deviation markers, ne 1. Implementace:
  `diff_trees/2` flat_mapuje per top-level pair s per-branch
  `mark_deviation_points`.
- Žádný JavaScript, žádný `live_component` — čistý LiveView sigil.

---

## Cassettes (`/cassettes/*`)

Cassette je DB-backed snapshot payload streamu pro daný `run_id`, replayovatelný
přes normální `SessionGenServer → Pipeline → Ledger` cestu. **Žádný bypass
hash-chainu** — replay produkuje samostatný validní chain pod novým `run_id`,
porovnatelný se zdrojem přes `Evals.Comparator`.

Use cases:
1. **Regression testing** — "nezměnil se span strom agenta po update modelu?"
2. **Replay pod Eval** — cassette jako `run_b` v `Evals.Comparator.compare`
3. **Offline debugging** — bez API calls, bez kreditu

### HTTP API

```
POST   /cassettes/record           # snapshot existujícího run_id do cassety
GET    /cassettes/:cassette_id     # detail + spans
GET    /cassettes                  # metadata list (DESC by recorded_at)
POST   /cassettes/:cassette_id/replay   # replay pod novým run_id
```

Auth: `Authorization: Bearer <token>` (AuthPlug platí přes `forward "/cassettes"`).

```bash
# 1. Nahraj run
curl -X POST http://localhost:4000/ingest \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"run_id":"cassette-demo","spans":[
       {"span_id":"s1","name":"llm_call",
        "started_at":"2026-05-17T10:00:00Z","ended_at":"2026-05-17T10:00:01Z",
        "attributes":{"model":"claude-sonnet-4-6"}}]}'

# 2. Record cassette
curl -X POST http://localhost:4000/cassettes/record \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"run_id":"cassette-demo","cassette_id":"cas-001","name":"LLM baseline"}'
# → 201 {"cassette_id":"cas-001","run_id":"cassette-demo","span_count":1,"recorded_at":"..."}

# 3. Replay + diff
curl -X POST http://localhost:4000/cassettes/cas-001/replay \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" -d '{}'
# → 200 {"run_id":"replay-cas-001-...","span_count":1,"hash_valid":true,"diff":[]}
```

Response invariant: `hash_valid` je `true` iff `Ledger.verify_ledger(new_run_id)`
vrátil `{:ok, _}` (chain validní); `false` znamená chain corrupted (nikdy by se
nemělo stát pro identický replay). `diff` je výstup `Evals.Comparator.compare`
mezi zdrojovým a replayovaným `run_id` (struktura `[%{"span_name", "type", ...}]`,
`[]` pro identický replay).

### Replayer semantics

`SpanChain.Cassettes.Replayer` je **pure modul** (žádný GenServer, žádný
`spawn_link`). `replay/2` běží v caller procesu (HTTP request, test process):

1. Subscribe na `"run:#{new_run_id}"` topic
2. `SessionSupervisor.ensure_session(new_run_id)` + `SessionGenServer.ingest_spans`
3. **Multi-batch wait**: receive loop na `{:spans_flushed, ^run_id}` broadcastů +
   `Repo.aggregate` count check dokud DB count ≥ expected. Cassette s N spans
   emituje `ceil(N / batch_size)` broadcastů (batch_size default 50) → replay
   nesmí vrátit po prvním, musí čekat na všechny.
4. `Ledger.verify_ledger(new_run_id)` + `Evals.Comparator.compare(source, new_run_id)`
5. `Phoenix.PubSub.unsubscribe` v `after` bloku (i při timeout / raise)

Klíčový invariant: post-GF-703 broadcast firi **AŽ PO** `Repo.transaction`
commit a connection release. Receive loop má tedy garanci že po každém broadcastu
jsou rows viditelné a Broadway connection je zpět v poolu — žádný sandbox race.

### Architecture

→ viz [`docs/arch/eval-and-replay.md`](arch/eval-and-replay.md) (pure replay engine
`receive` loop, payload-first snapshot, pasivní asociace na Evals, subscribe-order
invariant / `Registry.unregister/2`).

### Async replay přes `/api` (GF-798/803)

Výše uvedený `POST /cassettes/:id/replay` (port 4000, `Cassettes.Router`) je
**synchronní** (200/408, 15s self-bound) a zůstává beze změny. Pro React UI byl
přidán **asynchronní** variant na `/api` scope (port 4001, `Web.ApiController`):

```bash
# 1. Enqueue — vrátí 202 okamžitě (Bandit nedrží konexi)
curl -X POST http://localhost:4001/api/cassettes/cas-001/replay \
  -H "Authorization: Bearer dev-secret-change-me"
# → 202 {"job_id":"<uuid>","status":"running"}

# 2. Poll dokud status != "running"
curl http://localhost:4001/api/cassettes/replay_jobs/<job_id> \
  -H "Authorization: Bearer dev-secret-change-me"
# → {"id":"<uuid>","status":"completed","result":{"run_id":...,"span_count":...,"hash_valid":true,"diff":[]}}
#   (nebo {"status":"failed","result":{"error":"..."}})
```

- `Cassettes.enqueue_replay/2` vloží `ReplayJob` (`replay_jobs` tabulka, uuid PK,
  jsonb `result`) se `status: "running"` a spustí `run_replay_job` přes
  `Task.Supervisor.start_child(SpanChain.TaskSupervisor, …)` (fire-and-forget).
  `run_replay_job` volá stejný `Cassettes.replay` (tedy `Replayer.replay`) v task
  procesu → `{:ok}`→`completed`, `{:error}`/rescue→`failed`. `Replayer` beze změny.
- Frontend: `useReplay` hook (`assets/src/hooks/useReplay.js`, GF-803) je polling
  state machine — POST → poll `replay_jobs/:id` každých 1.5s rekurzivním
  `setTimeout` (40 pokusů ≈ 60s timeout guard), `running`→`completed`/`failed`.
- Omezení v1: `try/rescue` nezachytí `:EXIT` (externally killed task) → job zůstane
  `"running"`; budoucí periodický sweep à la GF-788.

### Cassette Workflow

Quick-reference end-to-end (detaily viz sekce výše).

**Create cassette (snapshot run):**
`POST /cassettes/record` (port 4000, `Cassettes.Router`)
Required: `run_id` (string), `cassette_id` (string, user-defined)
Optional: `name` (string)
Response 201: `{cassette_id, run_id, name, span_count, recorded_at}`
Error 404: `"run has no ledger rows"` — run neexistuje nebo nemá ledger data

**List cassettes:**
`GET /api/cassettes` (port 4001)
Response: `{offset, total, limit, cassettes: [...]}`
(cassette objekty: `id`, `run_id`, `name`, `recorded_at`, `inserted_at` — metadata-only, **bez** `span_count`/`snapshot`, aby velký list netáhl celé payloady)

**Replay cassette (async, GF-798):**
`POST /api/cassettes/:cassette_id/replay` (port 4001)
Response 202: `{job_id, status}`
Poll: `GET /api/cassettes/replay_jobs/:id` → `{id, status, result}` (`result` = `{run_id, span_count, hash_valid, diff}` po `completed`)
(Sync varianta: `POST /cassettes/:cassette_id/replay` na portu 4000 → 200 `{run_id, span_count, hash_valid, diff}`)

Pozn.: `Cassettes.Router` (port 4000) je Plug sub-router forwardovaný z `Ingestion.Router` (record + sync replay).
`ApiController` cassette actions (port 4001) jsou pro management React UI (list, async replay, job polling).

---

## OTLP/HTTP JSON endpoint `/v1/traces`

GhostFactory přijímá OpenTelemetry-native `OTLP/HTTP JSON` na portu 4000 vedle
vlastního `/ingest` formátu. Žádný Protobuf, žádná nová mix dep — `Plug.Parsers`
JSON stačí. OTLP/HTTP JSON je plnohodnotná součást OTel specifikace.

**Endpoint:** `POST /v1/traces` (`Plug.Router`, port 4000)
**Auth:** `Authorization: Bearer <token>` přes `AuthPlug` (stejný jako `/ingest`)
**Response:** `200` + `{"partialSuccess": {"rejectedSpans": 0}}` (OTLP spec — ne 202)

**Translation rules** (v `lib/.../ingestion/otlp_translator.ex`):

- `run_id` ← `resource.attributes["service.instance.id"]` (chybí → `400`)
- `traceId` / `spanId` / `parentSpanId` — hex string passthrough
- `startTimeUnixNano` / `endTimeUnixNano` (string ns) → ISO 8601 UTC s microsecond
  precision (Elixir `DateTime` neumí nanosekundy; ns truncated na μs — L2 acceptable)
- Atributy: KeyValue list → flat `%{key => value}` map; podpora `stringValue`,
  `intValue`, `boolValue`. `doubleValue`, `arrayValue`, `kvlistValue` + neznámá
  pole (`kind`, `status`, `events`, `links`, `traceState`, ...) tiše ignorovány.
- Více `resourceSpans` v jednom requestu — seskupení podle `run_id` (`Enum.each`
  → `SessionGenServer.ingest_spans/2` per skupina)

**Architecture:** Hexagonal — `OtlpTranslator` je hloupý adaptér na HTTP boundary.
Downstream (SGS → BufferProducer → Pipeline → Ledger, hash chain) **netknut**.
Stejná cesta jako `/ingest`, jen jiný vstupní shape.

**Smoke test:**

```bash
curl -X POST http://localhost:4000/v1/traces \
  -H "Authorization: Bearer dev-secret-change-me" \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.instance.id","value":{"stringValue":"otlp-test"}}]},"scopeSpans":[{"spans":[{"traceId":"abc","spanId":"def","name":"llm_call","startTimeUnixNano":"1716000000000000000","endTimeUnixNano":"1716000001000000000","attributes":[]}]}]}]}'

# → 200 {"partialSuccess":{"rejectedSpans":0}}
# → GET http://localhost:4001/trail/otlp-test viditelný v Trail UI
```

---

## PubSub broadcast

Pipeline broadcastuje po každém úspěšném `Ledger.insert_batch` přes `Phoenix.PubSub`.
Broadcast je defenzivní (try/rescue/catch) — Pipeline nikdy nepadne kvůli PubSub výpadku.

Topics:
- `"run:#{run_id}"` → `{:spans_flushed, run_id}` — detail view
- `"runs"` → `{:run_updated, run_id}` — index view

`TrailLive` subscribuje v `handle_params/3` (ne `mount/3`) — `connected?(socket)` guard.
`maybe_resubscribe/2` unsubscribuje starý topic při navigaci mezi run_ids.

---

## Python SDK

Separate Python package in `../ghostfactory-sdk/` (sibling of `gf_experiment/`).
Uses `httpx` async + `contextvars.ContextVar` for per-task isolation. **Never**
`threading.local` (would share state across coroutines).

Post-GF-741 (Sprint 7): exporter posílá **OTLP/HTTP JSON na `/v1/traces`**
(parita s TS SDK), ne legacy `{run_id, spans: [...]}` formát. Mapping
`span.run_id` → `resource.attributes["service.instance.id"]` (kanonický
OTel klíč; backend `OtlpTranslator.extract_run_id/1` čte výhradně tento).
Veřejné API (`gf.init`/`@gf.trace`/`gf.span`) beze změny.

Install + test (Python 3.11+):

```bash
cd ../ghostfactory-sdk
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"     # Windows
# source .venv/bin/activate && pip install -e ".[dev]"     # Unix
pytest
# → 21 passed in ~2.4s
```

Smoke test against a running backend (requires `mix phx.server`):

```python
import asyncio
import ghostfactory as gf

gf.init(
    endpoint="http://localhost:4000",
    api_key="dev-secret-change-me",
    run_id="python-test-1",
)

@gf.trace(name="agent_run")
async def run():
    async with gf.span("llm_call", model="claude-sonnet-4-6") as s:
        await asyncio.sleep(0.05)
        s.set("output", "hello world")
        s.set("prompt_tokens", 128)
    async with gf.span("tool_call", tool_name="search"):
        await asyncio.sleep(0.02)
    return "done"

asyncio.run(run())
# → Trail: http://localhost:4001/trail/python-test-1
```

For SDK usage examples (`attrs`, token tracking, agent config versioning,
eval support, attribute type dispatch), see
[`ghostfactory-sdk/README.md`](../../ghostfactory-sdk/README.md).

Auth header is `Authorization: Bearer <token>` (matches `SpanChain.Ingestion.AuthPlug`).
The SDK never raises to the caller — send-path failures are silent debug log
+ in-memory buffer fallback (`deque(maxlen=1000)`).

---

## TypeScript SDK

Separate Node.js package in `../ghostfactory-ts-sdk/` (sibling of `gf_experiment/`
and `ghostfactory-sdk/`). Uses native `fetch` (Node 18+) + `AsyncLocalStorage`
from `node:async_hooks` for per-task isolation. Targets the OTLP/HTTP JSON
endpoint `/v1/traces` (not `/ingest` — TS SDK is the standard-OTel front door).

Install + test (Node.js 18+):

```bash
cd ../ghostfactory-ts-sdk
npm install
npm run typecheck    # tsc --noEmit, strict mode
npm run build        # dist/index.js + dist/index.d.ts
npx vitest run       # 10 tests incl. AsyncLocalStorage isolation
```

Smoke test against a running backend (requires `mix phx.server`):

```typescript
import gf from "@ghostfactory/sdk";

gf.init({
  endpoint: "http://localhost:4000",
  apiKey: "dev-secret-change-me",
  runId: "ts-smoke-1",
});

const result = await gf.span("agent_run", { model: "claude-sonnet-4-6" }, async () =>
  gf.span("nested", {}, async () => "ok")
);
await gf.flush();
// → http://localhost:4001/trail/ts-smoke-1 zobrazí 2 spans s nested parent_span_id
```

For SDK usage examples (`attrs`, token tracking, agent config versioning,
eval support, attribute type dispatch), see
[`ghostfactory-ts-sdk/README.md`](../../ghostfactory-ts-sdk/README.md).

Auth header is `Authorization: Bearer <token>` (matches `SpanChain.Ingestion.AuthPlug`).
SDK never raises to the caller — send-path failures are silent
(`process.env.GF_DEBUG=1` for debug output). Spans buffered (50 / 5 s); call
`await gf.flush()` for explicit drain before process exit.

**vs Python SDK** (Sprint 8 parity snapshot — kontrakt detail v
[`docs/arch/sdk-contract.md`](arch/sdk-contract.md)):

| Concern | Python SDK | TypeScript SDK |
|---|---|---|
| Endpoint | `/v1/traces` (OTLP, GF-741) | `/v1/traces` (OTLP) |
| Payload | `{resourceSpans: [...]}` | `{resourceSpans: [...]}` |
| `run_id` attribute | `service.instance.id` | `service.instance.id` |
| Send model | per-span on context exit | buffered 50 / 5 s + `flush()` |
| Eval ID | `set_eval_id` / `eval_scope` per-task isolated (GF-727 / GF-744) | `evalScope` per-task isolated via `AsyncLocalStorage` (GF-733) — parita s Python |
| Attribute typy | int/bool/float dispatch (GF-742) | int/bool/float dispatch (GF-742) |
| Token / agent / reasoning / task attrs | `attrs` module — `gen_ai.*` + `gf.usage.*` + `gf.agent.*` + `gf.reasoning.*` + `gf.task.*` + `hash_prompt` (GF-735 / GF-738 / GF-736 / GF-737) | `attrs` namespace — same constants + `hashPrompt` (cross-language string-value parita testem) |
| Context | `contextvars.ContextVar` | `AsyncLocalStorage` |
| Span IDs | `secrets.token_hex(8)` | `randomBytes(8).toString('hex')` |
| Trace IDs | n/a (single span per request) | `randomBytes(16).toString('hex')` per root |

---

## Useful commands while developing

```bash
mix format                                    # apply formatting
mix test --failed                             # rerun only failures from the last run
mix test test/span_chain/ledger_test.exs   # one file
mix test --seed 0                             # deterministic order
mix ecto.rollback                             # undo the last migration
mix ecto.drop && mix ecto.create && mix ecto.migrate   # full reset (destructive) — `mix ecto.reset` is NOT an alias here
mix deps.tree                                 # who pulled in this transitive dep
cd assets && npm run dev                      # Vite dev server :5173 (proxy /api → :4001)
cd assets && npm run build                    # build React → priv/static/app.js + app.css
```

When you change a migration file that has already been applied locally, `mix ecto.rollback` then `mix ecto.migrate` is the correct fix — do not edit applied migrations.

---

## Frontend (`assets/` — React + Vite, GF-792a/794/795/797/799/801/803)

The Span Chain UI is a React 19 + Vite 8 app under `gf_experiment/assets/`. Phoenix serves
the built bundle from `priv/static/`; there is no separate production frontend server.

- **Build entry is `assets/index.html`** (standard Vite HTML entry, GF-801 — was `src/main.jsx`).
  Vite processes it, rewrites `<script type="module" src="/src/main.jsx">` → the built `/app.js`,
  and injects the `/app.css` `<link>`. Output: `priv/static/index.html` + `app.js` + `app.css` —
  **all three are now Vite build output** (gitignored). `assets/index.html` carries no manual
  `/app.css`/`/tokens.css` links (they'd fail Vite resolution); `main.jsx` imports both stylesheets
  so tokens bundle into `app.css`. `emptyOutDir: false` keeps the still-tracked `priv/static/tokens.css`
  on disk. `tokens.css` is **no longer in the `Plug.Static` whitelist** (GF-801 — nothing links it;
  `layouts.ex` is inline `<style>`), so it's served by nothing but stays tracked.
- **One-command build: `mix assets.deploy`** (GF-796) — runs `npm ci --prefix assets`
  (deterministic install from `package-lock.json`) followed by `npm run build --prefix assets`.
  The generated `index.html`/`app.js`/`app.css` are **gitignored** — regenerate from a clean
  checkout with this alias; do not commit them. No `phx.digest`: `index.html` hard-links `/app.js`
  statically, so fingerprinted filenames would 404. For dev use `cd assets && npm run dev`.
- **Caching (GF-799):** `Plug.Static` sets `cache_control_for_etags: "public, max-age=0, must-revalidate"`
  → the browser caches assets but revalidates via ETag → `304 Not Modified` when unchanged.
- **Dev loop:** `npm run dev` runs Vite on **:5173** and proxies `/api` + `/health` to the
  Phoenix endpoint on **:4001**. Production: `npm run build`, then Phoenix serves the assets.
- **All network access goes through `src/api/client.js` (`apiFetch`)** — the single `fetch`
  wrapper (Bearer auth; optional `options` arg for POST; surfaces backend `error` JSON).
  **GF-795:** `apiFetch` validates the `gf_token` from localStorage per-call — a non-string or
  >256-char value is removed and an `InvalidTokenError` is thrown before any request (prevents a
  Bandit `431` from a corrupt/oversized token); no token → no `Authorization` header (backend 401;
  there is no hardcoded dev fallback — set `localStorage.gf_token` in DevTools for local dev until
  the token UI in GF-802). Components never call `fetch` directly; they consume hooks in `src/hooks/`
  (`useRuns`/`useRun`/`useSpanPayload`/`useVerify`, plus GF-794
  `useEvals`/`useEval`/`useEvalCompare`/`useCassettes`/`useReplay`).
- **`/api` JSON endpoints** (read-only except replay, Bearer auth, GF-789): `GET /api/runs`,
  `/api/runs/:run_id` (spans skeleton — includes `span_id`, GF-793), `/api/runs/:id/spans/:pk`
  (full payload), `/api/runs/:id/verify`, `/api/evals`, `/api/evals/:id`,
  **`GET /api/evals/:id/compare?run_a&run_b`** (GF-793 — `summary` + `differences`),
  `/api/cassettes`, **`POST /api/cassettes/:id/replay` (async, GF-798 — 202 + `job_id`)** +
  **`GET /api/cassettes/replay_jobs/:id`** (poll). `useReplay` (GF-803) is the polling state machine
  consuming these (see the *Async replay přes `/api`* section above).
- **Span tree hierarchy:** the Dossier `SpanTree` builds depth from each span's `span_id`
  and `parent_span_id` (GF-793 exposes `span_id` in the run-detail response), so the tree
  reflects real parent→child nesting rather than a flat list. **GF-797:** when no span has a
  `span_id` (legacy data), `SpanTree` shows a "⚠ Span hierarchy unavailable — legacy data format"
  banner above the flat list instead of silently degrading.
