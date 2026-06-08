<!-- Source: architecture-map.md §6 — Broadway -->

## 6. Broadway — why it's here and how it works

### Problem: HTTP Acceptor Exhaustion (pre-GF-667)

Before GF-667 the SGS called `Ledger.insert_batch` itself, synchronously. Under a stress
test with 100+ concurrent clients this led to:

1. The SGS calls `Ledger.insert_batch` in `handle_call` (blocks the SGS).
2. The SQLite single-writer holds the lock → other inserts wait on `SQLITE_BUSY`.
3. The Bandit acceptor pool has a limited number of processes. Each HTTP request takes an
   acceptor → which calls `SGS.ingest_spans/2` synchronously (`GenServer.call`) →
   waits for the SGS to finish the DB insert.
4. Under enough load all acceptors block → new requests
   queue up in the TCP accept queue → eventually a reset.

GF-667 fixed it: **separating the synchronous hash computation (fast, ~50 µs) from
the asynchronous DB persistence** via the Broadway pipeline. After `build_entries` the SGS
immediately casts to the BufferProducer and returns 202. The DB write happens in the background.

### Broadway producer/consumer model

```
BufferProducer (GenStage :producer)            Pipeline (Broadway consumer)
─────────────────────────────────              ─────────────────────────────
state: %{queue: :queue, demand: N}             Processor.handle_message (passthrough)
                                                          ↓
SGS.cast {:enqueue, entries}                   Batcher (50 / 1000ms)
  → enqueue into queue                                    ↓
  → dispatch/1: emit min(queue, demand)        handle_batch/4
                                                 → Repo.transaction(insert_batch)
                                                 → with_retry 3× exp backoff
                                                 → broadcast OR DeadLetter
```

**Demand model (pull)** — the critical difference from a push queue:

1. The Producer does NOT emit messages until the Processor says "send me N messages".
2. The Processor requests demand only when it has free capacity (after finishing a batch).
3. If queue ≥ demand → emit N and clear the demand counter.
4. If queue < demand → emit what you have, store the remaining demand (`state.demand`).
5. When a new enqueue cast arrives → call dispatch again.

Implementation in `buffer_producer.ex:90-109`. No overload — when the SGS casts
faster than SQLite can insert, the queue grows in memory (in-memory `:queue`,
not ETS, not disk). For L2 that's acceptable; L3 will move to a persistent queue
(NATS JetStream, GF-648).

### Why `rest_for_one` and what would happen with `one_for_one`

From `application.ex:31-40` and `development.md:295-332`:

PipelineSupervisor wraps `[BufferRegistry, Pipeline]` with the `:rest_for_one` strategy.
The child order MUST be this — on a crash of child X, `rest_for_one` restarts
ONLY child X **and all children after it**, leaving the earlier ones running.

**Scenario with `one_for_one` (incorrect)**:
1. BufferRegistry crash.
2. `one_for_one` restarts it → a fresh ETS table, with no registrations.
3. BufferProducer lives INSIDE the Broadway tree (not directly under PipelineSupervisor),
   so it is not restarted.
4. BufferProducer's `init/1` is NOT called again (init is only called on spawn).
5. No self-re-registration in the fresh BufferRegistry → `Registry.lookup(:singleton)` returns `[]`.
6. `SGS.enqueue/1` returns `{:error, :no_producer}`. Silent losses.

**Scenario with `rest_for_one` (correct)**:
1. BufferRegistry crash.
2. `rest_for_one` restarts the Registry **AND** everything after it → Pipeline restart.
3. The Pipeline restart cascades into the Broadway internals → Broadway respawns BufferProducer.
4. The new BufferProducer.init/1 IS called → `Registry.register(BufferRegistry, :singleton, nil)` → re-registration in the fresh Registry.
5. SGS lookups work immediately.

**Why scope `PipelineSupervisor` to just 2 children, not the root as `rest_for_one`**:
If the root were `rest_for_one`, a crash of anything in ingestion (SessionSupervisor,
PipelineSupervisor, Bandit, ...) would take down everything after it (PubSub, Phoenix Endpoint).
The blast radius is deliberately small — only `[BufferRegistry, Pipeline]`. The higher
levels are isolated by the root `one_for_one`.

**Known edge case GF-724** (`development.md:362-380`): `Process.exit(reg, :kill)`
directly on the BufferRegistry supervisor blows up the root supervisor due to an ETS name
race. Synthetic test only — in production a Registry partition self-recovers without an
external kill. L3 followup: GF-729.

### Concurrency (GF-779, post-Postgres GF-704)

`pipeline.ex` Broadway opts:
- Producer: 1 (singleton, BufferRegistry depends on a unique key) — unchanged
- Processors: `System.schedulers_online()` (prod/dev) / 1 (test seam)
- Batchers: 4 + `partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end` (prod/dev) / 1 (test)

Postgres MVCC allows concurrent `insert_all`. `partition_by` MUST hash
(`:erlang.phash2`) — Broadway computes `rem(func.(msg), concurrency)`, a bare string
`run_id` would crash with `ArithmeticError`. Same run_id → same batcher partition
(per-session serialization), different run_ids in parallel. Test env pinned to 1 via the
seams `broadway_processor_concurrency` / `broadway_batcher_concurrency`.

### Retry semantics

`pipeline.ex:197-224` — 3 attempts, exp backoff `500 → 1000 → 2000 ms` in prod
(test override 1ms, keeps the negative tests under 50ms). After exhaustion:
`Message.failed/2` → `handle_failed/2` → `DeadLetter.store/3`. The hash chain
in the Ledger continues without the missing rows (the SGS `prev_hash` stays advanced) →
`verify_ledger` returns it as `chain_broken` — a deliberate audit signal.

---

