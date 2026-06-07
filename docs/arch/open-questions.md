<!-- Source: architecture-map.md §10 — Open otázky + known gaps -->

## 10. Open otázky a known limitations

Z `docs/development.md:206-214` (sekce „Open L2 limitations") + dodatečně:

### GF-733 (tracked): TS SDK `setEvalId` module-level
`ghostfactory-ts-sdk/src/client.ts` ukládá eval_id do module-level config,
ne do `AsyncLocalStorage`. Pro single-run script bez problému; pro paralelní
`Promise.all` runs kde každý task volá `setEvalId(...)` nezávisle dochází k
last-writer-wins race condition. Python SDK má stejné API přes `ContextVar`
(GF-727 / GF-744) a je per-task izolovaný. Fix: přesunout do
`AsyncLocalStorage` po vzoru `_currentSpanId`. Tracked, ne-blocking pro L2
(eval_id přes `gf.init({ evalId })` per-run je jednodušší cesta).

### Buffer není persistentní
`BufferProducer` je in-memory `:queue.queue()` (`buffer_producer.ex:73`).
Crash celého BEAM procesu → ztráta entries které opustily SGS ale ještě
nedoběhly Broadway batch. Žádný recovery — SDK má vlastní buffer (Python
deque/1000, TS in-memory list) ale jen pro send-path failures, ne pro
backend crash. L3: persistent queue (NATS JetStream, GF-648/GF-650).

### Postgres throughput baseline (GF-704 + GF-779)
`Pipeline batchers: concurrency: 4 + partition_by run_id` (`pipeline.ex`).
Dev-box Docker Postgres: ~6k spans/s (100×100), >4k spans/s i při 1000 sessions
(viz `docs/stress-test-results-2026-05-27.md`). Nižší než SQLite in-process baseline
(Docker/TCP overhead) + low-volume latence vyšší (partition_by trickle tradeoff) —
hodnota = cross-session souběžnost + produkční Postgres cesta, ne dev-box spans/s.

### GF-704 (L3): Revize `with_retry` při přechodu na Postgres
Aktuálně `Ledger.Behaviour.insert_batch/1` (`ledger_behaviour.ex:14`) vrací
raw `{n, nil | [...]}` tuple — selhání signalizováno přes `raise` (Ecto
driver konvence). `Pipeline.with_retry/3` catchuje raise → `{:error, _}` →
retry. Postgres driver má jiné failure modes (deadlock, connection lost) —
možná by tagged-tuple `{:ok, n} | {:error, reason}` callback byl vhodnější
jakmile nepoužíváme raise pro chyby.

### GF-729 (L3): BufferRegistry permanent supervisor výše v hierarchii
Edge case GF-724 (`development.md:362-380`): `Process.exit` na celý
BufferRegistry supervisor způsobí ETS name race během rest_for_one restart
→ root supervisor padá. Working as Intended pro `:kill` signál (BEAM
fail-fast), ale L3 by mohl Registry povýšit do root supervisoru aby crash
neměl cascade efekt na PipelineSupervisor. Diagnóza potvrzena 2026-05-18
(Gemini + Grok review).

### Pre-GF-703 telemetry race (rezolvovaný, kept jako paper trail)
Telemetry `[:gf, :ledger, :batch_insert, :stop]` firil UVNITŘ
`Repo.transaction`, takže LiveView/Replayer probuzeni před commit visibility
→ `Repo.all` občas vrátil stale data + Sandbox `owner exited` error v
testech. Fix: `safe_broadcast/1` PO `Repo.transaction` return (`pipeline.ex:80-91`).
Telemetry stop event zůstal kvůli kompatibilitě (uvnitř transakce stále),
ale produkční signál pro „can read now" je PubSub broadcast.

### `Cassettes.Replayer` runtime ownership
Replayer běží v caller procesu (HTTP request, Task.Supervisor task, nebo test
process), ne v dedicated GenServer. Důvod: PubSub subscription + cleanup tied
to caller lifecycle. Trade-off: dlouhotrvající replay (>15 s default timeout)
bloku caller thread.

**GF-798 (implementováno):** předpovězený „dedicated job + job-id polling" model
je teď live pro `/api` scope — `POST /api/cassettes/:id/replay` enqueue-ne
`ReplayJob` (`replay_jobs` tabulka) a spustí Replayer ve `Task.Supervisor`
(`SpanChain.TaskSupervisor`) tasku → HTTP request se NEblokuje (vrátí 202 +
`job_id` okamžitě), frontend polluje `GET /api/cassettes/replay_jobs/:id`. Ne
GenServer (jak naivně předpovězeno) — `Task.Supervisor` + Ecto stav stačí, Replayer
zůstal beze změny (jen běží v task procesu). Port-4000 `Cassettes.Router` replay
zůstává synchronní (HTTP request je caller, 15s self-bound). Omezení v1: `try/rescue`
nezachytí `:EXIT` (killed task) → job zůstane "running"; budoucí sweep à la GF-788.

**GF-807/805 (sweeper):** `ReplayJobSweeper` reapuje stale `"running"` joby (`:EXIT` killy)
na `"failed"` po threshold + maže staré terminal joby.

**GF-827 (ghost-task guard):** `cancel_replay_job/1` flipne job na `"cancelled"`, ale
fire-and-forget task běží dál a po dokončení by terminal stav přepsal. Proto je terminal
zápis (`run_replay_job/1`→`finish_replay_job/3`) atomický conditional `Repo.update_all` s
`WHERE status = "running"` — jakmile je řádek `"cancelled"` (cancel) nebo `"failed"`
(sweeper), zápis matchne 0 řádků a je no-op. Invariant: cancelled job žádný jiný proces
nepřepíše (žádný check-then-write race). `terminate_child` záměrně vynechán (node-local op
nepřežije L3 Horde) — definitivní řešení = cooperative shutdown přes PubSub.

**GF-832 (new_run_id unique):** `replay_jobs.new_run_id` je nově DB-unique (`create unique_index`)
+ `ReplayJob.changeset` `unique_constraint(:new_run_id)`. Poslední obrana za `get_replay_job_for_run/1`
`ORDER BY inserted_at DESC LIMIT 1` safety netem; duplicitní enqueue → `{:error, changeset}` →
`ApiController.replay_cassette/2` 409 `new_run_id_already_exists` (ne raised `Ecto.ConstraintError`
ani `CaseClauseError → 500`).

### Eval `Comparator.compare/2` je pure, ale Repo.all může být drahý
Comparator pro každý compare call dělá 2× `from Ledger where run_id == ^x order_by`.
Pro velké runy (10k+ spans) to znamená 20k+ row fetch + tree construction
v paměti. Žádný caching. Acceptable pro L2 (manuální compare UI); pro
auto-compare scheduler (L3) bude potřeba materializovaný diff cache.

---

## Known gaps (discrepancies vs prompt task)

- **`lib/span_chain/replay/` neexistuje** — feature je v `lib/span_chain/cassettes/`
  (`replayer.ex`, `router.ex`) a doménový API/schema v `lib/span_chain/cassettes.ex`
  + `cassette.ex`. Pojmenování v prompt task je pre-GF-712 historické.
- ~~**`pipeline_supervisor.ex` neexistuje jako samostatný soubor**~~ — resolved
  in **GF-739**: standalone modul `lib/span_chain/ingestion/pipeline_supervisor.ex`
  (`use Supervisor`); `application.ex` jen odkazuje na něj v `broadway_children/0`.
- **`/health` endpoint** — implementován v `router.ex:38-40`, neuvedeno v prompt task
  ani v `docs/development.md` toplevel.
- **`/v1/traces` endpoint a OTLP/HTTP** — GF-649 přidán v Sprintu 4, kompletně
  popsán v `development.md:637-674`. Není v `## Architecture` snapshot
  v CLAUDE.md jako primární cesta, ale je production-ready.
- **L0 reference stack** (Agent + Orchestrator + AgentRegistry + AgentSupervisor)
  běží v root supervision tree (`application.ex:14-17`) — není v ingestion cestě,
  ale spotřebovává resources. Prompt task ho zmiňuje jako „DO NOT MODIFY".
