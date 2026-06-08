<!-- Source: architecture-map.md §2 — Supervision tree -->

## 2. Supervision tree — visual map + explanation

```
SpanChain.Supervisor                                   strategy: :one_for_one
│
├── SpanChain.Repo                                     (Ecto.Repo, Postgres — GF-704)
│
├── L0 reference stack (DO NOT MODIFY)
│   ├── Registry SpanChain.AgentRegistry               keys: :unique
│   ├── DynamicSupervisor SpanChain.AgentSupervisor    strategy: :one_for_one
│   └── SpanChain.Orchestrator                         (GenServer)
│
├── L1 — Ingestion sessions
│   ├── Registry SpanChain.Ingestion.SessionRegistry   keys: :unique
│   └── SpanChain.Ingestion.SessionSupervisor          (DynamicSupervisor, :one_for_one)
│       └── (children spawned on-demand)
│           SpanChain.Ingestion.SessionGenServer       per run_id
│
├── SpanChain.TaskSupervisor                          (Task.Supervisor — async replay jobs, GF-798;
│                                                          fire-and-forget run_replay_job, state in replay_jobs)
│
├── L2 — Async persistence (gated: :start_broadway_pipeline)
│   └── SpanChain.Ingestion.PipelineSupervisor         strategy: :rest_for_one  ← GF-672, GF-739
│       │                                                 (lib/span_chain/ingestion/pipeline_supervisor.ex)
│       ├── Registry SpanChain.Ingestion.BufferRegistry
│       └── SpanChain.Ingestion.Pipeline               (Broadway supervisor)
│           ├── Producer (SpanChain.Ingestion.BufferProducer, concurrency: 1)
│           ├── Processor :default (concurrency: schedulers_online prod/dev, 1 test — GF-779)
│           └── Batcher :default (size 50, timeout 1000ms prod / 50ms test, concurrency: 4 + partition_by run_id — GF-779)
│
├── HTTP listener (gated: :start_http_server)
│   └── Bandit + SpanChain.Ingestion.Router            port 4000
│
└── Web stack (gated: :start_phoenix_endpoint)
    ├── Phoenix.PubSub  name: SpanChain.PubSub
    └── SpanChain.Web.Endpoint                         port 4001 (LiveView /trail, /eval + JSON /api GF-789)
```

Source: `lib/span_chain/application.ex:10-23` + `broadway_children/0:41-61`.

### Per-node rationale

**`SpanChain.Repo`** — Ecto.Repo over Postgres (GF-704; formerly SQLite). The first child deliberately: everything
else persists through it. Crash → the root `one_for_one` restarts it independently;
SessionSupervisor and Pipeline crash on the first DB call and recover on their own.
WAL mode (`config.exs:15`) allows multi-reader (LiveView) without
blocking the Pipeline writer.

**Agent stack (Registry + DynamicSupervisor + Orchestrator)** — the L0 reference
implementation of an AI-agent stack from year 0 (`agent.ex` › "the basis for GF
replay: the Ledger is the source of truth"). Not in the ingestion path; runs in parallel
as a historical artifact.

**`SessionRegistry`** — an Erlang `Registry` (ETS-backed), required BEFORE
`SessionSupervisor` so that `via_tuple/1` (`session_gen_server.ex:69`) has somewhere
to register the pid. Registry crash → SessionSupervisor restarts (root
`one_for_one`) but existing SGS processes lose their registration and `ensure_session/1`
spawns new duplicates. Acceptable — the SGS themselves are idempotent via
the DB `on_conflict: :nothing` on the `(run_id, epoch_id, seq)` unique index.

**`SessionSupervisor`** — a `DynamicSupervisor` `:one_for_one`. Holds the
**per-run_id** SessionGenServers; one misbehaving SGS must not take down the other
running sessions. Spawn pattern: see `session_supervisor.ex:36-55` —
`telemetry.span` wrap + race-safe `{:already_started, pid}` handling.

**`PipelineSupervisor` (GF-672, GF-739)** — a standalone module
`lib/span_chain/ingestion/pipeline_supervisor.ex`, strategy
`:rest_for_one`. Wraps the pair `[BufferRegistry, Pipeline]`. The reason for this
sub-supervisor is explained in section 6.

**`BufferRegistry`** — a Registry for the singleton lookup of the BufferProducer pid
(BufferProducer lives INSIDE the Broadway supervision tree, not directly here —
`buffer_producer.ex:71-74` in `init/1` registers self).

**`Pipeline`** (Broadway supervisor) — spawns its own
Producer/Processor/Batcher processes underneath it. A crash of the whole Pipeline → `rest_for_one`
does NOT restart BufferRegistry (Pipeline is AFTER it); a crash of the Registry →
Pipeline restart is REQUIRED (Broadway respawns the Producer, which re-registers).

**`Bandit + Ingestion.Router`** — root `one_for_one`; a crash of the HTTP listener
must not take down the Pipeline or the SGS (in-flight data in the BufferProducer queue
stays in memory, but the L2 buffer is not persistent — see section 10).

**`Phoenix.PubSub`** — a child of the Endpoint supervisor tree. The Pipeline
broadcasts `{:spans_flushed, run_id}` and `{:run_updated, run_id}` to it
after every successful batch commit (`pipeline.ex:114-145`). PubSub crash →
broadcast silently fails (try/rescue in `safe_broadcast/1`), the Pipeline continues.

**`Web.Endpoint`** — the Phoenix endpoint for LiveView. In tests `server: false`
so the `Bandit` socket doesn't bind, but the Endpoint GenServer lives so PubSub
works (`config/test.exs:11-15`).

### OTP for people from Next.js

| OTP concept | Mental model from Node/React | Key difference |
|---|---|---|
| **GenServer** | A singleton service object with a message queue. Public API = `GenServer.call/cast`, server-side logic in `handle_call/handle_cast`. | Each GenServer is a separate OS-thread-like process (BEAM scheduler). The mailbox is FIFO, serial processing. A crash inside does NOT bring down the whole Node — the supervisor restarts it. |
| **Supervisor** | Something between `try/catch` and a `pm2 restart` daemon. Watches children and restarts them on crash per a strategy. | A crash is an expected control-flow tool, not an exceptional state. "Let it crash" = the equivalent of "restart on the first error instead of a defensive try/catch on every line". |
| **DynamicSupervisor** | `new Map<id, WorkerService>` where each value can self-heal. | Processes spawn on-demand (e.g. per HTTP request / per user) and live until the supervisor kills them. No manual `pool.acquire/release` semantics. |
| **Registry** | `Map<string, pid>` but ETS-backed, lock-free reads, automatic cleanup on the crash of a registered process. | Like a lookup table in Redis, but in-memory inside the BEAM. `via_tuple` is syntactic sugar for "send a message to the process whose key is X". |
| **Broadway** | A pipeline like a BullMQ / kue worker: producer → batchers → handlers, with built-in backpressure (pull demand model). | It's not a queue in another service (RabbitMQ); the producer is a process inside the same app and Broadway batching + retry is declarative in the `start_link/1` opts. |
| **PubSub (Phoenix)** | The same as socket.io rooms — broadcast/subscribe on a topic. | In-process (single node), no Redis. A subscriber is a process; a message arrives in its mailbox as an ordinary message. |

The key aha-moment from a Next.js perspective: here **each user/session/run
has its own `Worker` process inside the Node process**. Instead of
`req.session.userId` you have a PID. SessionGenServer = an isolated state container,
completely isolated from other sessions, but cheap (~2KB heap, you can have a million
on a laptop).

---

