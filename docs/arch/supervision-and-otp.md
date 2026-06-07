<!-- Source: architecture-map.md §2 — Supervision tree -->

## 2. Supervision tree — vizuální mapa + vysvětlení

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
│                                                          fire-and-forget run_replay_job, stav v replay_jobs)
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

**`SpanChain.Repo`** — Ecto.Repo nad Postgres (GF-704; dříve SQLite). První dítě záměrně: všechno
ostatní persistuje přes něj. Crash → root `one_for_one` ho samostatně
restartne; SessionSupervisor a Pipeline crashnou na první DB call a samy se
zvednou. WAL mód (`config.exs:15`) povolí multi-reader (LiveView) bez
blocking Pipeline writeru.

**Agent stack (Registry + DynamicSupervisor + Orchestrator)** — L0 reference
implementace AI-agentního stacku z roku 0 (`agent.ex` › „základ pro GF
replay: Ledger je source of truth"). Není v ingestion cestě; běží paralelně
jako historický artefakt.

**`SessionRegistry`** — Erlang `Registry` (ETS-backed), nutný BEFORE
`SessionSupervisor` aby `via_tuple/1` (`session_gen_server.ex:69`) měl kam
zaregistrovat pid. Crash registry → SessionSupervisor restartne (root
`one_for_one`) ale existující SGS procesy ztratí registraci a `ensure_session/1`
spawne nové duplikáty. Akceptovatelné — SGS samotné jsou idempotentní přes
DB `on_conflict: :nothing` na `(run_id, epoch_id, seq)` unique index.

**`SessionSupervisor`** — `DynamicSupervisor` `:one_for_one`. Drží
**per-run_id** SessionGenServery; jeden zlobný SGS nesmí strhnout ostatní
běžící sessions. Spawn pattern viz `session_supervisor.ex:36-55` —
`telemetry.span` wrap + race-safe `{:already_started, pid}` handling.

**`PipelineSupervisor` (GF-672, GF-739)** — standalone modul
`lib/span_chain/ingestion/pipeline_supervisor.ex`, strategie
`:rest_for_one`. Obaluje pár `[BufferRegistry, Pipeline]`. Důvod tohoto
sub-supervisoru je vysvětlen v sekci 6.

**`BufferRegistry`** — Registry pro singleton lookup BufferProducer pidu
(BufferProducer žije UVNITŘ Broadway supervision tree, ne přímo zde —
`buffer_producer.ex:71-74` v `init/1` registruje self).

**`Pipeline`** (Broadway supervisor) — sám si pod sebou spawne
Producer/Processor/Batcher procesy. Pád celé Pipeline → `rest_for_one`
restart BufferRegistry NEDĚLÁ (Pipeline je AFTER); pád Registry →
Pipeline restart MUSÍ (Broadway respawne Producer, který se re-registruje).

**`Bandit + Ingestion.Router`** — root `one_for_one`; pád HTTP listeneru
nesmí strhnout Pipeline ani SGS (in-flight data v BufferProducer queue
zůstanou v paměti, ale L2 buffer není persistentní — viz sekce 10).

**`Phoenix.PubSub`** — child Endpoint supervisor stromu. Pipeline jí
broadcastuje `{:spans_flushed, run_id}` a `{:run_updated, run_id}`
po každém úspěšném batch commitu (`pipeline.ex:114-145`). PubSub crash →
broadcast silent fail (try/rescue v `safe_broadcast/1`), Pipeline pokračuje.

**`Web.Endpoint`** — Phoenix endpoint pro LiveView. V testech `server: false`
takže `Bandit` socket nebindí, ale Endpoint GenServer žije aby PubSub
fungovala (`config/test.exs:11-15`).

### OTP pro lidi z Next.js

| OTP koncept | Mentální model z Node/React | Klíčový rozdíl |
|---|---|---|
| **GenServer** | Singleton service object s message queue. Public API = `GenServer.call/cast`, server-side logika v `handle_call/handle_cast`. | Každý GenServer je samostatný OS-thread-like proces (BEAM scheduler). Mailbox je FIFO, sériové zpracování. Crash uvnitř NEPADÁ celý Node — supervisor restartne. |
| **Supervisor** | Něco mezi `try/catch` a `pm2 restart` daemon. Sleduje childs a restartuje je při crashi podle strategie. | Crash je očekávaný control-flow nástroj, ne výjimečný stav. „Let it crash" = ekvivalent „restart na první chybu místo defensive try/catch každého řádku". |
| **DynamicSupervisor** | `new Map<id, WorkerService>` kde každá hodnota umí self-heal. | Procesy se spawnou on-demand (např. per HTTP request / per user) a žijí dokud je supervisor nezabije. Žádná manuální `pool.acquire/release` semantika. |
| **Registry** | `Map<string, pid>` ale ETS-backed, lock-free reads, automatický cleanup na crash registrovaného procesu. | Jako lookup table v Redisu, ale uvnitř BEAM in-memory. `via_tuple` syntaktický cukr pro „pošli zprávu procesu jehož klíč je X". |
| **Broadway** | Pipeline jako BullMQ / kue worker: producer → batchers → handlers, s built-in backpressure (pull demand model). | Není to fronta v jiném service (RabbitMQ); producer je proces uvnitř té samé app a Broadway batching + retry je deklarativní v `start_link/1` opts. |
| **PubSub (Phoenix)** | Stejné jako socket.io rooms — broadcast/subscribe na topic. | In-process (single node), žádný Redis. Subscriber je proces, message přijde do jeho mailboxu jako běžná zpráva. |

Klíčový aha-moment z Next.js perspektivy: tady **každý uživatel/session/run
má svůj vlastní `Worker` proces uvnitř Node procesu**. Místo
`req.session.userId` máš PID. SessionGenServer = isolated state container,
kompletně izolovaný od ostatních sessions, ale levný (~2KB heap, milion lze
mít na laptopu).

---

