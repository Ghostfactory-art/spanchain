# GhostFactory Observability — Architecture Map

> Living architectural reference covering all modules of the `span_chain`
> backend (L1 + L2 + L3 foundation; post Sprint 13). Module names, function
> signatures and line counts last reviewed 2026-06-04 (Postgres per GF-704;
> React/Vite frontend GF-792a; `span_id` + Evals compare GF-793; Evals/Cassettes
> React wiring GF-794; `replay_jobs.new_run_id` UNIQUE + 409 guard GF-832;
> OTLP per-group `with/else` GF-849; `/api` run_id validace GF-850;
> Trail run-list order_by `inserted_at` GF-855).
> Citations from `@moduledoc` are marked with `›`.

---

## 1. Přehled: Co tento systém dělá

GhostFactory Observability je **append-only audit-trail backend pro AI agenty**:
přijímá OTLP-style spans přes HTTP, počítá pro každý span SHA256 hash navázaný
na předchozí (hash-chain), persistuje je do Postgres Ledgeru a poskytuje
real-time read UI (`/trail`), strukturální porovnání běhů (`/evals`) a
deterministický VCR replay (`/cassettes`). Vrstva L1 = synchronní hash-chain
v SessionGenServeru; vrstva L2 = asynchronní persistence přes Broadway pipeline.
Klient (Python/TS SDK) je hloupý — backend drží veškerou logiku integrity a porovnávání.

---

## 2. Supervision tree — přehled

Root `SpanChain.Supervisor` (`:one_for_one`) + sub-supervisor `PipelineSupervisor`
(`:rest_for_one`, GF-672) obalující `[BufferRegistry, Pipeline]`. Per-node rationale,
restart strategie a OTP-pro-Next.js mentální model.

→ Detail: [`arch/supervision-and-otp.md`](arch/supervision-and-otp.md)

---

## 3. Datový tok — end-to-end flow (přehled)

HTTP POST `/ingest` → `AuthPlug` → `Ingestion.Router` → `SessionGenServer` (synchronní
in-memory hash) → `BufferProducer` → Broadway `Pipeline` (metadata upserty + `Ledger.insert_batch`)
→ Postgres + `Phoenix.PubSub` broadcast.

→ Detail: [`arch/data-flow.md`](arch/data-flow.md)

---

## 4. Modul-Dependency Matrix

| Modul | Závisí na | Závisí na něm |
|---|---|---|
| `SpanChain.Application` | všechny child specs | — (boot entry) |
| `SpanChain.Repo` | Ecto, postgrex (GF-704; dříve ecto_sqlite3) | Ledger, DeadLetter, Run, Eval, Cassette, Evals, Cassettes, TrailLive, EvalLive, Pipeline (přes Repo.transaction + `ensure_run_records/1` + `ensure_eval_records/1` + `upsert_agent_configs/1` — GF-751/GF-746/GF-748), Harness (nepřímo). **Po GF-751** SGS Repo závislost úplně zmizela. |
| `SpanChain.Ledger` | `Repo`, `PayloadSerializer`, `Ledger.Behaviour` | SGS, Pipeline, Cassettes, Cassettes.Replayer, Evals.Comparator, TrailLive, EvalLive (nepřímo), Web.ApiController (GF-789), property testy, ledger_test. **Hash vstup** (GF-787): `compute_hash/7` = `seq:prev_hash:event_type:payload:parent_span_id:run_id:epoch_id` — `run_id`+`epoch_id` přidány do hashe, takže entry je kryptograficky vázána ke svému runu/epoše (ne jen SQL filtrem ve `verify_ledger`). **Projekce columns** (GF-669 + GF-653 + GF-790): `span_id`, `trace_id`, `started_at`, `ended_at`, `status` — žádný z nich není v `compute_hash/7` vstupu; `payload` zůstává autoritativní integrity zdroj. **GF-790:** `status` plněn v `build_entry` z `payload["status"]` (per-span status pro waterfall error highlight) |
| `SpanChain.Ledger.Behaviour` | — | Ledger (implements), pipeline_negative_test stubs |
| `SpanChain.PayloadSerializer` | `Jason` | Ledger (canonical_encode), Harness (serialize_value) |
| `SpanChain.DeadLetter` | `Repo`, `Ecto.Changeset`, `Logger` | Pipeline (handle_failed), dead_letter_test |
| `SpanChain.Run` | `Eval` (belongs_to FK) | Pipeline (`ensure_run_records/1` + `upsert_agent_configs/1` — GF-751/GF-748), Evals (list_run_ids), Comparator (load_run) |
| `SpanChain.Eval` | `Run` (has_many) | Evals (create/get), Pipeline (`ensure_eval_records/1` — GF-746) |
| `SpanChain.Cassette` | `Ecto.Changeset` | Cassettes (record/get), Cassettes.Replayer |
| `SpanChain.Evals` | `Eval`, `Run`, `Repo`, `Evals.Comparator` | Evals.Router, Web.EvalLive |
| `SpanChain.Evals.Comparator` | `Ledger`, `Repo`, `Run` | Evals (defdelegate), Web.EvalLive, Cassettes.Replayer |
| `SpanChain.Evals.Router` | `Evals`, `Plug.Router` | Ingestion.Router (forward) |
| `SpanChain.Cassettes` | `Cassette`, `Ledger`, `Repo`, `Replayer`, `ReplayJob`, `Task.Supervisor` (GF-798) | Cassettes.Router, Web.ApiController (async replay), cassettes_test. **GF-798:** `enqueue_replay/2` (insert `ReplayJob` "running" → `Task.Supervisor.start_child(SpanChain.TaskSupervisor, run_replay_job)` → `{:ok, job}`), `run_replay_job/1` (reuse `replay/2`; `{:ok}`→completed / `{:error}`/rescue→failed), `get_replay_job/1` (non-bang, UUID-cast guarded). **GF-823:** `cancel_replay_job/1` (UUID-guarded; `pending`/`running`→`"cancelled"`, terminal→`:already_terminal`, unknown→`:not_found`) — backuje `DELETE /api/cassettes/replay_jobs/:id`. **GF-828:** `get_replay_job_for_run/1` (read-only; přímý `new_run_id` match — `:string` sloupec, **ne** UUID, bez cast; `order_by inserted_at desc` + `limit 1` → `Repo.one` safe; `nil`/non-binary → `nil`) → backuje `ApiController.get_run` `replay_job` enrichment pro cancelled-replay banner. |
| `SpanChain.Cassettes.Replayer` | `Cassette`, `Ledger`, `Repo`, `Comparator`, `SessionSupervisor`, `SessionGenServer`, `Phoenix.PubSub` | Cassettes (replay), replayer_test. **Beze změny v GF-798** — pure modul, jen běží v Task.Supervisor task procesu místo HTTP request procesu (sync port-4000 `/cassettes/*` ho stále volá v request procesu). |
| `SpanChain.Cassettes.ReplayJob` | `Ecto.Schema`, `Ecto.Changeset` | Cassettes (`enqueue_replay`/`get_replay_job`/`run_replay_job`/`cancel_replay_job`), Web.ApiController (polling + cancel). GF-798: `replay_jobs` tabulka (uuid PK, jsonb `result`), stav `running`→`completed`/`failed`. GF-823: `changeset/2` má `validate_inclusion(:status, [...])` vč. `"cancelled"` (cancel cesta). GF-827: terminal zápis přes `run_replay_job/1`→`finish_replay_job/3` je atomický `Repo.update_all` s `WHERE status = "running"` (changeset helper `update_replay_job/2` odstraněn) — cancelled job ghost Task nepřepíše. **GF-832:** migrace `create unique_index(:replay_jobs, [:new_run_id])` (sloupec `null: false`, fresh per job → plain unique index je plná garance) + `changeset/2` `unique_constraint(:new_run_id)` → DB violation se vrátí jako `{:error, changeset}` (ne raised `Ecto.ConstraintError`). DB-level poslední obrana za `get_replay_job_for_run/1` `ORDER BY … LIMIT 1` safety netem. |
| `SpanChain.Cassettes.ReplayJobSweeper` | `Repo`, `ReplayJob`, `Ecto.Query` | application.ex (root child, za TaskSupervisor). **GF-807/805:** periodic GenServer se dvěma sweepy — `sweep_stuck_jobs/0` (`update_all` stale `running` jobs `inserted_at < now - threshold` → `failed`/`%{"error"=>"timeout_or_killed"}`; chytá `:EXIT` killy, které `run_replay_job/1` rescue nezachytí) + `sweep_retention/0` (`delete_all` completed/failed starší než 30 dní). Obě veřejné pro test bez mountu; intervaly + threshold přes config seamy (`stuck_sweep_interval_ms`/`retention_sweep_interval_ms`/`stuck_stale_threshold_s`). |
| `SpanChain.Cassettes.Router` | `Cassettes`, `Plug.Router` | Ingestion.Router (forward) |
| `SpanChain.Ingestion.Router` | `AuthPlug`, `RateLimiter`, `ValidationPlug`, `OtlpTranslator`, `SessionGenServer`, `SessionSupervisor`, `Evals.Router`, `Cassettes.Router`, `Plug.Router` | Bandit listener (Application). **GF-849:** `handle_otlp/1` iteruje span groups přes `Enum.reduce` s per-group `with/else` (zrcadlí `do_ingest/3`) — `{:error, reason}` z `ensure_session`/`ingest_spans` loguje (`[OTLP] …`) + pokračuje místo bare-match `MatchError → 500` (zahodil zbývající groups); status 200 + `partialSuccess` s přesným `rejectedSpans`. |
| `SpanChain.Ingestion.AuthPlug` | `Plug.Conn`, `Plug.Crypto.secure_compare`, `Application.get_env` | Ingestion.Router |
| `SpanChain.Ingestion.RateLimiter` | `PlugAttack`, `Plug.Conn`, `Jason`, `PlugAttack.Storage.Ets` | Ingestion.Router (pipeline plug ZA AuthPlug, PŘED Plug.Parsers). GF-766: per-API-key throttle (Bearer token jako klíč, ne IP — X-Forwarded-For je spoofable). Limit `:rate_limit_count`/`:rate_limit_period_ms` (default 1000/60s); nad limit → 429 `rate_limit_exceeded` + `Retry-After` přes `block_action/3` + `halt()`. ETS storage worker (`PlugAttack.Storage.Ets`, name `SpanChain.Ingestion.RateLimiter`) v Application supervision tree před HTTP listenerem. Test seam: `:rate_limit_enabled` (false v `config/test.exs`) přes overridnuté `call/2`. **GF-785:** první rule `"allow health check"` (`if conn.request_path in ["/health","/health/"]` → `allow(true)`) — `/health` exempt z throttle (LB health-check nedostane 429); nil pro ostatní cesty → throttle beze změny. |
| `SpanChain.Ingestion.ValidationPlug` | `Plug.Conn`, `Jason`, `@valid_id_regex` | Ingestion.Router (pipeline plug po Plug.Parsers, před `:match`). GF-767: path-scoped na `request_path == "/ingest"` — sanitizuje `run_id` (required) + `agent_id` (optional) regexem `^[a-zA-Z0-9_-]{1,128}$`; malformed → 400 `invalid_id_format` + `halt()` dřív, než data dorazí do SGS. Ostatní routy (`/health`, `/v1/traces`, `/evals`, `/cassettes`) propouští beze změny. **GF-774:** veřejná `valid_run_id?/1` (deleguje na `valid_id?(_, :required)`, stejný `@valid_id_regex`) volána z `Router.handle_otlp` pro `/v1/traces` run_id (plug `call/2` path-scope beze změny). **GF-850:** `valid_run_id?/1` reused i z `Web.ApiController` (:4001) — single-source regex contract napříč oběma porty. |
| `SpanChain.Ingestion.OtlpTranslator` | (pure, žádné dependencies) | Ingestion.Router (handle_otlp) — `extract_run_id/1` (`service.instance.id`) + `extract_eval_id/1` (`gf.eval_id`) + `translate_span/1` emituje snake_case payload (`"span_id"`, `"trace_id"`, `"parent_span_id"`) → konzumováno Ledger.build_entry projekcemi (GF-653 Scénář A audit) |
| `SpanChain.Ingestion.SessionSupervisor` | `SessionGenServer`, `SessionRegistry`, `DynamicSupervisor`, **GF-775 recovery:** `Repo`, `Ledger`, `Phoenix.PubSub` (`fetch_last_epoch`/`fetch_last_hash`/`await_epoch_drain` — Repo read VÝHRADNĚ zde, SGS zůstává Repo-free). **GF-782:** `await_epoch_drain` → `drain_until_silence/3` (drainuje do `silence_ms` ticha, ne jen první `{:epoch_flushed}`; seam `epoch_drain_silence_ms` 200ms/75ms — multi-batch `chain_broken` fix, ADR-003 uzavřeno). **GF-786:** `epoch_drain_timeout` NENÍ config key — derivováno `broadway_batch_timeout_ms * 10 + 200` (sleduje runtime `BATCH_FLUSH_TIMEOUT_MS`; prod 1200ms / test 700ms) + `Logger.warning` na drain timeout | Ingestion.Router, Cassettes.Replayer, Harness, session_supervisor_test |
| `SpanChain.Ingestion.SessionGenServer` | `Ledger`, `BufferProducer`, `SessionRegistry` | SessionSupervisor (start_child), Ingestion.Router, Harness, Cassettes.Replayer, session_gen_server_test. **Public API:** `ingest_spans/2` (legacy) + `ingest_spans/3` (GF-727 late-binding via `opts[:eval_id]`); telemetry `[:gf, :sgs, :late_bind_eval_id]` fires max 1× per SGS lifetime. **Po GF-751 (commit `9c7f03c`):** SGS je čistý in-memory hash-chain bez DB závislostí (`Repo`/`Run`/`Eval`/`Ecto.Query` aliasy odstraněny); `:eval_id` se přilepí k entries v `append_span/2` jako in-memory sidecar (Pipeline strippne před `Ledger.insert_batch`). **GF-775:** `restart: :temporary` (crash NEauto-restart → recovery via `ensure_session`); `start_link`/`init` přijímají `epoch_id`+`prev_hash` (spawn opts; SGS stále Repo-free). |
| `SpanChain.Ingestion.BufferProducer` | `Broadway.NoopAcknowledger`, `BufferRegistry`, `GenStage` | SGS (enqueue), Pipeline (producer module via config), buffer_producer_test |
| `SpanChain.Ingestion.Pipeline` | `Broadway`, `BufferProducer` (via config), `Ledger` (via config), `DeadLetter` (via config), `Repo`, `Run`, `Ecto.Query`, `Phoenix.PubSub`, private `with_retry/3` | Application (child via PipelineSupervisor), pipeline_test, pipeline_negative_test. **Metadata fáze** (`handle_batch/4`, GF-751/GF-746/GF-748): `ensure_run_records/1` → `ensure_eval_records/1` → `upsert_agent_configs/1` PŘED `insert_batch`. Defensive rescue na každé fázi — failure nesmí crashnout pipeline ani zablokovat ledger insert. **GF-779:** processors `schedulers_online` / batcher 4 + `partition_by: :erlang.phash2(run_id)` (test env 1 přes seamy). **GF-775:** broadcast `{:epoch_flushed, run_id, epoch_id}` po commitu (crash recovery drain signál). **GF-777:** `batch_timeout` default 100ms (`config.exs`; reálný zdroj 1000ms byl config.exs ne pipeline hardcode; prod env var `BATCH_FLUSH_TIMEOUT_MS` v `runtime.exs`, guard `!= :test`). **GF-790:** `ensure_run_records/1` grupuje per `run_id` + derivuje `runs.started_at` jako nejstarší span `started_at` (`Enum.min` nil-safe) + `on_conflict` LEAST upsert (query forma; konverguje napříč dávkami, nahradil `on_conflict: :nothing`). |
| `SpanChain.Ingestion.TelemetryLogger` | `:telemetry`, `Logger` | Application.start (attach), development.md |
| `SpanChain.Harness` | `SessionGenServer`, `SessionSupervisor`, `PayloadSerializer` | uživatelský Elixir kód, harness_test |
| `SpanChain.Web.Endpoint` | `Phoenix.Endpoint`, `Bandit.PhoenixAdapter`, `Web.Router`, `PubSub` | Application |
| `SpanChain.Web.Router` | `Phoenix.Router`, `Web.TrailLive`, `Web.EvalLive`, `Web.ApiController` (GF-789), `Corsica`, `Ingestion.AuthPlug`, `Web.RateLimiter` (GF-851), `Web.Layouts` | Web.Endpoint |
| `SpanChain.Web.RateLimiter` (GF-851) | `PlugAttack`, `Plug.Conn`, `Jason`, `PlugAttack.Storage.Ets` | Web.Router (plug v `:api` ZA AuthPlug + v `:browser` po `:accepts`), api_controller_test. Rate limiting pro port 4001: `:api` per Bearer token (storage `Web.RateLimiter.Api`), veřejné `/trail` per client IP (storage `Web.RateLimiter.Trail`). IP klíč z `x-forwarded-for` (Caddy přidává reálnou client IP; fallback `conn.remote_ip` pro lokální curl) — NE raw `remote_ip` (za proxy by všichni sdíleli jednu IP). Oddělené ETS tabulky → `/api` a `/trail` buckety nezávislé, žádné sdílení s portem 4000. Limity zrcadlí 4000 přes stejné config klíče (`:rate_limit_count`/`:rate_limit_period_ms`, default 1000/60s); nad limit → 429 `rate_limit_exceeded` + `Retry-After` přes `block_action/3` + `halt()`. Test seam `:rate_limit_enabled` (false v `config/test.exs`) přes overridnuté `call/2`. Dvě ETS storage workers v Application tree před endpointem. XFF je spoofable — robustnější `Plug.RemoteIp` je Later (nová dependency). |
| `SpanChain.Web.TrailLive` | `Ledger`, `Repo`, `Phoenix.PubSub`, `Phoenix.LiveView` | Web.Router (live route), trail_live_test |
| `SpanChain.Web.EvalLive` | `Eval`, `Evals`, `Evals.Comparator`, `Phoenix.LiveView` | Web.Router (live route), eval_live_test |
| `SpanChain.Web.ApiController` (GF-789) | `Phoenix.Controller`, `Plug.Conn`, `Ecto.Query`, `Repo`, `Ledger`, `Evals`, `Cassettes` | Web.Router (`:api` scope), api_controller_test. Read-only JSON API pod `/api` (port 4001): runs list/detail/span/verify, evals list/detail, cassettes list/replay. OOM-safe: list/skeleton jen nativní sloupce (žádný `payload`/JSONB extrakce), payload jen v `get_span`; span/error counts grouped-count + `Map.new`. `:api` pipeline = Corsica (CORS, PRVNÍ) → `:accepts json` → AuthPlug (Bearer reuse). Catch-all `options "/*path"` route, aby OPTIONS preflight prošel pipeline. **GF-828:** `get_run/2` vrací top-level pole `replay_job` (`%{status: "cancelled"} | nil` přes `Cassettes.get_replay_job_for_run/1`) — sibling `run`/`spans`, krmí cancelled-replay banner v Dossieru. **GF-832:** `replay_cassette/2` dostal klauzuli `{:error, %Ecto.Changeset{}}` → 409 `new_run_id_already_exists` (duplicitní `new_run_id` z `unique_constraint` — dřív dormantní cesta → `CaseClauseError → 500`). **GF-850:** run_id format validace na :4001 (reuse `Ingestion.ValidationPlug.valid_run_id?/1`) — `plug :validate_run_id when action in [:get_run, :get_span, :verify_run]` → 400 `invalid_run_id` před DB; `replay_cassette/2` inline guard na user `new_run_id` před `enqueue_replay`. Zavírá GF-842b audit Finding F3. **GF-855:** `list_runs` řadí `order_by [desc: inserted_at]` (monotonic row-creation time), NE nullable/derived `started_at` (null run plave nahoru přes NULLS FIRST, stale-date run klesá dolů → run vypadá „chybějící"); select rozšířen o `inserted_at` pro Trail „Filed" (FileCard/RegisterRow). |
| `SpanChain.Agent` (L0 ref) | — (isolated) | Orchestrator |
| `SpanChain.Orchestrator` (L0 ref) | `Agent`, `AgentSupervisor` | Application (root child) |
| `SpanChain.StressTest` | SGS / HTTP (load generator) | manual `mix run -e` invocation |
| `SpanChain.Release` (GF-783) | `Ecto.Migrator`, `Application` | OTP release boot (`entrypoint.sh` → `bin/span_chain eval "SpanChain.Release.migrate()"`); infra-only migration helper pro Docker self-hosting, žádný runtime konzument |
| `ghostfactory.attrs` (Python SDK) | `hashlib` (stdlib) | span_chain uživatelé; `gf.attrs.*` re-exportováno z `__init__.py`. Konstanty: `GEN_AI_*` (GF-735 OTel GenAI spec) + `GF_USAGE_COST_USD` + `GF_AGENT_*` (GF-738 GF extension) + `GF_REASONING_*` (GF-736 reasoning capture) + `GF_TASK_*` (GF-737 task delegation) + `hash_prompt(text)` utility (SHA-256[:16] fingerprint). |
| `attrs` (TS SDK, `src/attrs.ts`) | `node:crypto` (Node builtin) | re-exportováno přes `export * as attrs from "./attrs.js"` v `index.ts`. Stejné konstanty jako Python (literal types přes `as const`) — včetně `GF_REASONING_*` (GF-736) a `GF_TASK_*` (GF-737) — plus `hashPrompt(text)`. Cross-language hash parita pinned by test (`hashPrompt("") === "e3b0c44298fc1c14"`). |

Acyklická kontrola: žádný modul nezávisí na svém downstream konzumentu.
Comparator/Cassettes závisí na Ledger; Ledger nezávisí na Comparator. Web vrstvy
závisí na doménách; domény nezávisí na webu. ✅

---

## 5. Hash-chain invariant — přehled

hash-chain invariant: `compute_hash/7` (GF-787) kryptograficky váže entry ke svému
`run_id`+`epoch_id`; `verify_ledger/1`, `canonical_encode`, epoch boundary a obrana proti
„Epoch Island Attack". (lowercase `hash`)

→ Detail: [`arch/hash-chain.md`](arch/hash-chain.md)

---

## 6. Broadway — přehled

Broadway async persistence: producer/consumer model, proč `rest_for_one`, concurrency
(GF-779 post-Postgres GF-704) a retry sémantika s DeadLetter routingem.

→ Detail: [`arch/broadway-pipeline.md`](arch/broadway-pipeline.md)

---

## 7. Eval + Replay systém — přehled

Eval Framework (GF-706/707) + `Comparator` (pure tree diff) + VCR Cassettes/Replay
(GF-712) + async replay job model (GF-798) + web UI vrstvy (Trail/Eval/Dossier).

→ Detail: [`arch/eval-and-replay.md`](arch/eval-and-replay.md)

---

## 8. Test architektura — přehled

Jak testujeme OTP: `assert_receive` místo `Process.sleep`, Broadway telemetry barrier
pattern, `broadway_producer_module` config injection (ne Mox), property testy (StreamData).

→ Detail: [`arch/testing-otp.md`](arch/testing-otp.md)

---

## 9. SDK kontrakt — přehled

SDK kontrakt (Python + TypeScript): OTLP/HTTP JSON exporter, resource attribute klíče
(`service.instance.id`, `gf.eval_id`), per-span value coercion (`intValue` / `boolValue` /
`doubleValue` / `stringValue`) a `attrs` modul s `gen_ai.*` (OTel GenAI spec) + `gf.agent.*`
GF extension konstantami (+ `hash_prompt`). Princip „SDK stays dumb".

→ Detail: [`arch/sdk-contract.md`](arch/sdk-contract.md)

---

## 10. Open otázky a known limitations — přehled

Open otázky, known limitations + known gaps (discrepancies vs prompt task): buffer není
persistentní, L3 revize `with_retry`/BufferRegistry, resolved paper-trails.

→ Detail: [`arch/open-questions.md`](arch/open-questions.md)

---

## Detailní sekce (arch/)

Detailní próza těchto sekcí byla rozdělena do `arch/` (context refactor). Přehled výše,
§4 Dependency Matrix zůstává zde celá.

- §2 [`arch/supervision-and-otp.md`](arch/supervision-and-otp.md)
- §3 [`arch/data-flow.md`](arch/data-flow.md)
- §5 [`arch/hash-chain.md`](arch/hash-chain.md)
- §6 [`arch/broadway-pipeline.md`](arch/broadway-pipeline.md)
- §7 [`arch/eval-and-replay.md`](arch/eval-and-replay.md)
- §8 [`arch/testing-otp.md`](arch/testing-otp.md)
- §9 [`arch/sdk-contract.md`](arch/sdk-contract.md)
- §10 [`arch/open-questions.md`](arch/open-questions.md)
