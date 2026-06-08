# ADR-003 — SGS Crash Recovery: Race-Safe Design

**Date:** 2026-05-26 (implemented 2026-05-27)
**Status:** IMPLEMENTED (commit `4a3f8b2`)
**Issue:** GF-775
**Authors:** Jiří Joneš + Gemini + Grok (three-model review, Sprint 11)

---

## Context

`SessionGenServer` (SGS) holds the hash-chain state (`prev_hash`, `seq`, `epoch_id`)
in memory. After an OTP crash → auto-restart starts `init/1` with empty state
(`seq: 0`, `prev_hash: nil`). Result: a corrupted hash-chain for that `run_id`.

The GF-768 audit confirmed: `verify_ledger/1` after crash → restart → ingest returns
`{:error, :chain_broken}`. The test in `session_gen_server_test.exs` explicitly
asserts this (comment: flip to `{:ok, _}` once this ADR is implemented).

### Why the naive fix doesn't work

**Variant A: Repo read in `init/1` or `handle_continue`**
- Violates a hard rule from CLAUDE.md: "Don't add any Repo. call to
  SessionGenServer" (GF-751 — a deliberate architectural decision)
- Async race: `BufferProducer` survives the SGS crash. In-flight spans flush
  after the SGS restarts. A recovery read would read a stale DB position → collision.

**Variant B: Naive supervisor-level recovery without drain**
- `ensure_session/1` reads the last position from the DB, passes it into the SGS
- The stale-read problem remains — in-flight spans aren't in the DB yet at the moment of the
  recovery read.

---

## Decision

**Epoch rollover + supervisor-level recovery + drain signal**

### Mechanism

#### 0. SGS `restart: :temporary` (enabler)

> **Implementation correction vs the original design.** Recovery in
> `ensure_session/1` runs only when the Registry is empty. But the SGS was a
> `:permanent` DynamicSupervisor child → after a crash the supervisor auto-restarted it
> with stale state (`epoch 0`, `prev_hash: nil`) EVEN BEFORE the next
> `ensure_session/1` call → recovery never ran. The SGS is therefore now
> `use GenServer, restart: :temporary`: a crashed SGS does not auto-restart,
> the Registry empties, and the next ingest via `ensure_session/1` performs recovery.
> A crashed run has its in-memory cursor down until the next span (the data is safely
> in the DB).

#### 1. Epoch rollover on every SGS restart

Each SGS restart increments `epoch_id`. The old epoch is closed.

```elixir
# In SessionSupervisor.ensure_session/1 on restart detection (Registry empty,
# the run is in the DB). The Repo read lives EXCLUSIVELY here (GF-751):
last_epoch = fetch_last_epoch(run_id)          # max(epoch_id) from the DB
await_epoch_drain(run_id, last_epoch)          # see #2
prev_hash = fetch_last_hash(run_id)            # the last committed hash (after the drain)
spawn_session(run_id, epoch_id: last_epoch + 1, prev_hash: prev_hash)
```

Epoch rollover eliminates the collision between old (in-flight) and new spans —
different `epoch_id` → different sequence space → `on_conflict: :nothing` on
`(run_id, epoch_id, seq)` will never collide.

> **Implementation correction: `prev_hash` is CARRIED from the DB, NOT `nil`.** The original design
> started the new epoch with `prev_hash: nil`. But that would itself be
> `{:error, :chain_broken}`: `verify_ledger/1` enforces GF-666 cross-epoch
> continuity (iterates `(epoch_id ASC, seq ASC)` linearly and carries `last_hash` across
> epoch boundaries; `prev_hash: nil` is allowed ONLY for the very first record
> `epoch 0, seq 0`). So `ensure_session/1` reads the last committed hash and
> passes it as the `prev_hash` of the new epoch. This keeps `verify_ledger/1` **unchanged**
> and preserves Island Attack detection (deleting a whole epoch in the middle =
> `chain_broken`). The alternative "segment `verify_ledger` per epoch" was
> rejected — it regresses GF-666.

#### 2. In-flight drain before the new ingest

After an SGS crash there is a window where `BufferProducer`/Broadway can still commit
old spans. `ensure_session/1` waits for the drain signal BEFORE reading the last hash.

```elixir
# In ensure_session/1, before fetch_last_hash:
await_epoch_drain(run_id, old_epoch_id)
# subscribe "epoch_flush:#{run_id}", receive {:epoch_flushed, run_id, old_epoch_id}
# or timeout (default 1_200ms = batch_timeout + buffer, seam :epoch_drain_timeout_ms) — then no guarantee.
# Symmetric un/subscribe on every exit path.

# Pipeline.handle_batch broadcasts after EVERY successful commit, one signal
# per unique {run_id, epoch_id} in the batch (crash-safe, like safe_broadcast/1):
Phoenix.PubSub.broadcast(GfExperiment.PubSub,
  "epoch_flush:#{run_id}",
  {:epoch_flushed, run_id, epoch_id}
)
```

#### 3. The SGS stays Repo-free

The SGS makes no Repo calls — it preserves the GF-751 invariant. It receives the state (`epoch_id`,
`prev_hash`, `seq`) as a parameter at start from the supervisor
(`start_link/1` opts: `epoch_id` default 0, `prev_hash` default nil).

### Prerequisite: Postgres (GF-704) ✅

On SQLite the drain timeout was reliable only under low load. On Postgres,
read-after-write after commit is guaranteed (MVCC), so once `ensure_session/1`
receives `{:epoch_flushed}`, that batch IS visible. Both GF-704 and GF-779 (partition_by)
are merged; GF-775 was implemented after them.

---

## Alternatives that were rejected

| Alternative | Reason for rejection |
|---|---|
| Repo read in SGS `handle_continue` | Violates the CLAUDE.md/GF-751 invariant |
| Lower `batch_timeout` for a faster drain | Hurts throughput, SQLITE_BUSY risk |
| Persistent queue (NATS) for BufferProducer | L3 scope — beyond the L2 phase |
| Deploy without crash recovery | An audit trail product can't have a documented `:chain_broken` scenario |

---

## Code impact

| File | Change |
|---|---|
| `lib/gf_experiment/ingestion/session_gen_server.ex` | `restart: :temporary`; `start_link`/`init` accept `epoch_id` + `prev_hash` (defaults 0 / nil). Still 0× `Repo.` (GF-751) |
| `lib/gf_experiment/ingestion/session_supervisor.ex` | Recovery in `ensure_session/1`: `fetch_last_epoch` / `await_epoch_drain` / `fetch_last_hash` (Repo reads EXCLUSIVELY here) |
| `lib/gf_experiment/ingestion/pipeline.ex` | `handle_batch` broadcasts `{:epoch_flushed, run_id, epoch_id}` per unique `{run_id, epoch_id}` after commit |
| `test/gf_experiment/ingestion/session_gen_server_test.exs` | Crash recovery test rewritten: no auto-restart, recovery via `ensure_session`, assert `{:ok, 11}` |
| `test/gf_experiment/ingestion/session_supervisor_test.exs` | → `DataCase` (`ensure_session` now reads the DB → needs the sandbox) |

`verify_ledger/1` — **unchanged**. Continuity is preserved by the new epoch
**carrying `prev_hash` from the DB** (not by segmenting `verify_ledger` per epoch) — GF-666
cross-epoch continuity and Island Attack detection both remain valid.

---

## Known limitations

- **Multi-batch drain — RESOLVED (GF-782, commit `e5df46f`).** Originally `await_epoch_drain`
  returned after the FIRST `{:epoch_flushed}`; on a burst > `batch_size` (50) there were multiple in-flight batches →
  `fetch_last_hash` read a stale position → the new epoch's `prev_hash` pointed at a non-final hash →
  `verify_ledger/1` `{:error, :chain_broken}`. GF-780 only narrowed it in time (timeout 500→1_200ms).
  GF-782 resolves it structurally: `drain_until_silence/3` after the first flush drains until
  `silence_ms` of silence arrives (not just one message) → covers any number of in-flight batches. Seam
  `epoch_drain_silence_ms` (default 200ms = 2× the prod `batch_timeout` 100ms; `config/test.exs`: 75ms
  > the 50ms test batch_timeout). The outer `epoch_drain_timeout_ms` (1_200ms) stays a cold/fast-path guard
  (Broadway commits everything before `subscribe` → the timeout returns `:ok`, data committed).
- **A crashed run is left without an in-memory cursor** until the next span (a consequence of
  `restart: :temporary`). The data is in the DB; the cursor is rebuilt on the next ingest.

## Done When

- ✅ `verify_ledger/1` returns `{:ok, _}` after the scenario 5 spans → kill SGS → recovery
  via `ensure_session/1` → 6 spans (the test asserts `{:ok, 11}`; epoch 0 + epoch 1).
- ✅ Crash recovery test rewritten (no `:chain_broken` in `session_gen_server_test.exs`).
- ✅ `grep "Repo\." lib/gf_experiment/ingestion/session_gen_server.ex` → 0 hits.
- ✅ GF-704 (Postgres) + GF-779 (partition_by) merged before implementation.
- ✅ `mix test` → 157 tests, 0 failures (Postgres).

---

*ADR-003 · Status: IMPLEMENTED (GF-775, commit `4a3f8b2`; drain timeout tuning GF-780, commit `e65d608`; multi-batch drain-until-silence GF-782, commit `e5df46f`) · Linear: [ADR-003 document](https://linear.app/gf-aos/document/adr-003-sgs-crash-recovery-race-safe-design-f125e9c385a3)*
