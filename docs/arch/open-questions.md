<!-- Source: architecture-map.md §10 — Open questions + known gaps -->

## 10. Open questions and known limitations

From `docs/development.md:206-214` (the "Open L2 limitations" section) + additions:

### GF-733 (tracked): TS SDK `setEvalId` module-level
`ghostfactory-ts-sdk/src/client.ts` stores eval_id in module-level config,
not in `AsyncLocalStorage`. Fine for a single-run script; for parallel
`Promise.all` runs where each task calls `setEvalId(...)` independently there's a
last-writer-wins race condition. The Python SDK has the same API via `ContextVar`
(GF-727 / GF-744) and is per-task isolated. Fix: move to
`AsyncLocalStorage` following the `_currentSpanId` pattern. Tracked, non-blocking for L2
(eval_id via `gf.init({ evalId })` per-run is the simpler route).

### The buffer is not persistent
`BufferProducer` is an in-memory `:queue.queue()` (`buffer_producer.ex:73`).
A crash of the whole BEAM process → loss of entries that left the SGS but hadn't yet
made it through a Broadway batch. No recovery — the SDK has its own buffer (Python
deque/1000, TS in-memory list) but only for send-path failures, not for a
backend crash. L3: persistent queue (NATS JetStream, GF-648/GF-650).

### Postgres throughput baseline (GF-704 + GF-779)
`Pipeline batchers: concurrency: 4 + partition_by run_id` (`pipeline.ex`).
Dev-box Docker Postgres: ~6k spans/s (100×100), >4k spans/s even at 1000 sessions
(see `docs/stress-test-results-2026-05-27.md`). Lower than the SQLite in-process baseline
(Docker/TCP overhead) + higher low-volume latency (partition_by trickle tradeoff) —
the value = cross-session concurrency + the production Postgres path, not dev-box spans/s.

### GF-704 (L3): Revisit `with_retry` after the move to Postgres
Currently `Ledger.Behaviour.insert_batch/1` (`ledger_behaviour.ex:14`) returns
a raw `{n, nil | [...]}` tuple — failure signaled via `raise` (Ecto
driver convention). `Pipeline.with_retry/3` catches the raise → `{:error, _}` →
retry. The Postgres driver has different failure modes (deadlock, connection lost) —
a tagged-tuple `{:ok, n} | {:error, reason}` callback might be more suitable
once we no longer use raise for errors.

### GF-729 (L3): BufferRegistry permanent supervisor higher in the hierarchy
Edge case GF-724 (`development.md:362-380`): `Process.exit` on the whole
BufferRegistry supervisor causes an ETS name race during the rest_for_one restart
→ the root supervisor falls. Working as Intended for the `:kill` signal (BEAM
fail-fast), but L3 could promote the Registry into the root supervisor so a crash
has no cascade effect on PipelineSupervisor. Diagnosis confirmed 2026-05-18
(Gemini + Grok review).

### Pre-GF-703 telemetry race (resolved, kept as a paper trail)
The telemetry `[:gf, :ledger, :batch_insert, :stop]` fired INSIDE
`Repo.transaction`, so LiveView/Replayer were woken before commit visibility
→ `Repo.all` sometimes returned stale data + a Sandbox `owner exited` error in
tests. Fix: `safe_broadcast/1` AFTER the `Repo.transaction` return (`pipeline.ex:80-91`).
The telemetry stop event stayed for compatibility (still inside the transaction),
but the production signal for "can read now" is the PubSub broadcast.

### `Cassettes.Replayer` runtime ownership
The Replayer runs in the caller process (HTTP request, Task.Supervisor task, or test
process), not in a dedicated GenServer. Reason: the PubSub subscription + cleanup are tied
to the caller lifecycle. Trade-off: a long-running replay (>15 s default timeout)
blocks the caller thread.

**GF-798 (implemented):** the predicted "dedicated job + job-id polling" model
is now live for the `/api` scope — `POST /api/cassettes/:id/replay` enqueues a
`ReplayJob` (`replay_jobs` table) and runs the Replayer in a `Task.Supervisor`
(`SpanChain.TaskSupervisor`) task → the HTTP request does NOT block (returns 202 +
`job_id` immediately), the frontend polls `GET /api/cassettes/replay_jobs/:id`. Not a
GenServer (as naively predicted) — `Task.Supervisor` + Ecto state is enough, the Replayer
is unchanged (it just runs in a task process). The port-4000 `Cassettes.Router` replay
stays synchronous (the HTTP request is the caller, 15s self-bound). v1 limitation: `try/rescue`
doesn't catch `:EXIT` (killed task) → the job stays "running"; a future sweep à la GF-788.

**GF-807/805 (sweeper):** `ReplayJobSweeper` reaps stale `"running"` jobs (`:EXIT` kills)
to `"failed"` after a threshold + deletes old terminal jobs.

**GF-827 (ghost-task guard):** `cancel_replay_job/1` flips the job to `"cancelled"`, but
the fire-and-forget task keeps running and on completion would overwrite the terminal state. So the terminal
write (`run_replay_job/1`→`finish_replay_job/3`) is an atomic conditional `Repo.update_all` with
`WHERE status = "running"` — once the row is `"cancelled"` (cancel) or `"failed"`
(sweeper), the write matches 0 rows and is a no-op. Invariant: no other process overwrites
a cancelled job (no check-then-write race). `terminate_child` is deliberately omitted (a node-local op
won't survive L3 Horde) — the definitive solution = cooperative shutdown via PubSub.

**GF-832 (new_run_id unique):** `replay_jobs.new_run_id` is now DB-unique (`create unique_index`)
+ `ReplayJob.changeset` `unique_constraint(:new_run_id)`. The last line of defense behind the `get_replay_job_for_run/1`
`ORDER BY inserted_at DESC LIMIT 1` safety net; a duplicate enqueue → `{:error, changeset}` →
`ApiController.replay_cassette/2` 409 `new_run_id_already_exists` (not a raised `Ecto.ConstraintError`
or `CaseClauseError → 500`).

### Eval `Comparator.compare/2` is pure, but Repo.all can be expensive
For each compare call the Comparator does 2× `from Ledger where run_id == ^x order_by`.
For large runs (10k+ spans) that means 20k+ row fetch + tree construction
in memory. No caching. Acceptable for L2 (manual compare UI); for an
auto-compare scheduler (L3) a materialized diff cache will be needed.

---

## Known gaps (discrepancies vs the prompt task)

- **`lib/span_chain/replay/` does not exist** — the feature is in `lib/span_chain/cassettes/`
  (`replayer.ex`, `router.ex`) and the domain API/schema in `lib/span_chain/cassettes.ex`
  + `cassette.ex`. The naming in the prompt task is pre-GF-712 historical.
- ~~**`pipeline_supervisor.ex` doesn't exist as a separate file**~~ — resolved
  in **GF-739**: a standalone module `lib/span_chain/ingestion/pipeline_supervisor.ex`
  (`use Supervisor`); `application.ex` just references it in `broadway_children/0`.
- **`/health` endpoint** — implemented in `router.ex:38-40`, not mentioned in the prompt task
  or in `docs/development.md` top-level.
- **`/v1/traces` endpoint and OTLP/HTTP** — GF-649 added in Sprint 4, fully
  described in `development.md:637-674`. Not in the `## Architecture` snapshot
  in CLAUDE.md as the primary path, but production-ready.
- **L0 reference stack** (Agent + Orchestrator + AgentRegistry + AgentSupervisor)
  runs in the root supervision tree (`application.ex:14-17`) — not in the ingestion path,
  but consumes resources. The prompt task mentions it as "DO NOT MODIFY".
