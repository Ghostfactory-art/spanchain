# ADR-001 — Architecture Decisions

**Status:** Accepted
**Date:** 2026-05-16
**Layer:** L0 + L1 (foundation through persistent ingestion)

This document captures the load-bearing architectural choices in GhostFactory Observability Core and the reasoning behind each. Decisions are listed in the order they were made; later decisions assume earlier ones.

---

## 1. Elixir + OTP as the backend runtime

**Decision:** The backend is written in Elixir 1.19+ on OTP 28.

**Why:**

- **Actor model fits the domain.** Each agent session is a long-lived, independently-stateful conversation. Modeling one OS thread or one row-locked DB transaction per session does not scale; modeling one BEAM process per session does. Sessions are isolated by default — a crash in `run_id=abc` cannot corrupt `run_id=xyz`.
- **Supervision is free.** A `DynamicSupervisor` plus a `Registry` is the canonical OTP pattern for "spawn one process per identifier, restart on crash, look up by name." We get crash isolation, restart strategies, and graceful shutdown without writing them from scratch.
- **`:telemetry` is the ecosystem-wide observability spine.** Every well-behaved Elixir library emits `:telemetry` events. We instrument our own pipeline the same way (`[:gf, ...]` namespace), and downstream consumers (Prometheus, OpenTelemetry exporters) can be attached without touching call sites.
- **Hibernation + soft real-time GC.** Idle session processes hibernate after 5 minutes (`{:noreply, state, :hibernate}`), shrinking their heap to a few hundred bytes. 10,000 idle sessions cost ~10 MB total — flat-pricing memory regardless of agent fleet size.

**Trade-offs accepted:**

- Smaller hiring pool than Python/Go.
- BEAM is not the fastest single-threaded runtime; we trade raw throughput for concurrency primitives and operational visibility.

---

## 2. Hash-chain Ledger as the source of truth

**Decision:** Every event that happens during an agent session is appended to an immutable Ledger. Each Ledger entry contains the SHA-256 hash of its predecessor's hash plus its own content. **Replay reads the Ledger — it never re-runs the original code with the same inputs.**

**Why:**

- **Re-running is not replay.** LLM calls, tool calls with side effects, time-dependent code, and stochastic sampling all produce different outputs on the second run. "Same inputs → same outputs" is false for the systems we care about. The Ledger captures what actually happened, not what should happen if we ran it again.
- **Tamper-evidence.** If any field of any Ledger entry is modified after the fact, the chain hash recomputed from that row will not match the stored hash. `Ledger.verify_ledger/1` walks the chain and surfaces this as `{:error, :chain_broken}`. This makes the Ledger usable for audit trails where "did this agent take this action?" must be answerable with cryptographic evidence.
- **Single source of truth.** Decision context (`input`, `thinking`, `decision`, `output` for LLM calls) is stored inline in the Ledger entry payload rather than in a separate "decisions" table. There are no JOINs at replay time and no consistency window where the chain and its annotations diverge.

**Trade-offs accepted:**

- Storage is larger than a normalized schema. We carry duplicate metadata in payloads. This is the right trade for an audit log; we get O(1) replay reads.
- Hashing is sensitive to payload representation. See decision §6 for the canonical encoding choice.

---

## 3. Ledger row shape

**Decision:** Each row in the `ledger_entries` table has the following columns:

```text
run_id          :string   non-null  — agent session identifier
epoch_id        :integer  non-null  — rolls over every 1000 entries
seq             :integer  non-null  — sequence number within (run_id, epoch_id)
hash            :string   non-null  — SHA-256 hex digest of this entry
prev_hash       :string   nullable  — hash of the previous entry, NULL at epoch boundary
parent_span_id  :string   nullable  — parent span in the hierarchy, NULL at the root
event_type      :string   non-null  — discriminator: "span", "llm_call", "tool_call", ...
payload         :map      non-null  — event-specific data, stored as JSON
inserted_at     :utc_datetime_usec  — when the row was written to disk
```

Uniqueness is enforced by a composite index on `(run_id, epoch_id, seq)`. There is no surrogate primary key beyond `id`.

The hash input is:

```text
"#{seq}:#{prev_hash || "nil"}:#{event_type}:#{Jason.encode!(payload)}:#{parent_span_id || "nil"}"
```

See `lib/gf_experiment/ledger.ex` for the authoritative `compute_hash/5` implementation.

**Why these fields:**

- `(run_id, epoch_id, seq)` is enough to address any row deterministically without depending on database-assigned IDs.
- `prev_hash` is materialized rather than recomputed at read time so that `verify_ledger/1` is a single forward pass with no recursion.
- `event_type` is a column rather than a payload key because we index on it and want the discriminator visible in raw SQL.
- `payload :map` keeps the row open to new event types without schema migrations.

---

## 4. `parent_span_id` is part of the hash

**Decision:** `parent_span_id` is included in the hash input, not just stored as routing metadata.

**Why:**

If `parent_span_id` lived only in a separate column outside the hash, an attacker (or a buggy retention job) could rewrite a span's parent without invalidating the chain. The Ledger would still verify as intact, but the reconstructed call tree would be a lie.

Hierarchy changes the meaning of an event. An `llm_call` whose `parent_span_id` points to a `retry_handler` is a different fact from the same `llm_call` whose parent is `user_input` — same payload, different interpretation. Treating hierarchy as content (and therefore as part of the hash) preserves the audit guarantee end-to-end.

`parent_span_id` is nullable; the literal string `"nil"` is hashed when it is absent. Going from `nil` to any string changes the hash, which is exactly the property we want.

**Trade-offs accepted:**

- We cannot re-parent spans after they are written without breaking the chain. This is by design.

---

## 5. Epoch isolation — rolling over every 1000 events

**Decision:** A new `epoch_id` is started every 1000 events within a `run_id`. `seq` resets to 0 and `prev_hash` resets to `nil` at the boundary. `[:gf, :epoch, :boundary]` is emitted via `:telemetry` when the rollover happens.

**Why:**

- **Bounded verification cost.** Verifying a chain is O(n) in the number of entries since the last "trust anchor." Without epochs, a long-running session accumulates an unbounded chain. With epoch rollover, verifying any window is bounded by 1000 hashes.
- **No global locking.** Hash chains are isolated per `(run_id, epoch_id)`. Ten thousand concurrent agent sessions produce ten thousand independent chains; the only serialization point is the per-session `GenServer` mailbox, which is what we wanted anyway.
- **Operationally useful checkpointing.** An epoch boundary is a natural place to fan out work (retention, compaction, archival to cold storage) without coordinating with active writers.

**Trade-offs accepted:**

- A "chain" for a run is really a list of chains, one per epoch. Verification must iterate epochs in order, which is straightforward but worth noting.

---

## 6. Session is the unit of analysis, not LLM call

**Decision:** The `run_id` (one agent session) is the primary index for everything: process spawning, hash chain isolation, replay scoping, billing.

**Why:**

Most existing observability tools index on individual LLM calls. That model collapses when an agent makes one tool call, one retrieval call, three LLM calls, and a final decision — those events are causally linked and only make sense together. We index on the session so that "what did the agent decide and why" is a single query, not a JOIN across event tables.

This shows up in the API surface: `POST /ingest` takes a `run_id` and a list of `spans`. There is no separate `POST /llm_calls` endpoint. The Python/TS SDK is "dumb" — it batches spans by `run_id` and ships them; all event-type semantics live in the backend.

---

## 7. Two distinct kinds of "replay"

**Decision:** The system supports two operations, both called "replay" in casual speech, that work fundamentally differently:

| | **Audit Replay (L1)** | **Debug Replay (L2 — planned)** |
|---|---|---|
| Source | Read the Ledger | Intercept SDK I/O calls |
| Determinism | Cryptographically guaranteed | Best-effort cassette playback |
| When usable | After the agent has run | During development, before deployment |
| What it answers | "What did the agent actually do?" | "What would the agent do if I changed this prompt?" |
| Cost | One DB scan | Re-run with mocked I/O |

L1 is shipped (this codebase). L2 is on the L2 roadmap and uses a VCR-style cassette pattern, intercepting at the SDK level. The two are deliberately separate because they answer different questions and have different consistency guarantees.

**Why split them:**

Treating audit and debug as the same feature led, in earlier designs, to a "replay" function that was sometimes deterministic and sometimes not, with no clear signal to the caller. Separating them makes the contract explicit: audit replay always reads the Ledger and never re-executes; debug replay always re-executes against cassettes and never claims to reproduce production exactly.

---

## 8. `:telemetry` is for self-monitoring, not customer data

**Decision:** GhostFactory emits `:telemetry` events for its own pipeline (request handling, session lifecycle, ledger writes, epoch rollovers). It does **not** emit `:telemetry` for customer agent spans.

The emitted event prefixes are:

```text
[:gf, :ingest,  :request,      :start | :stop | :exception]
[:gf, :session, :spawn,        :start | :stop | :exception]
[:gf, :ledger,  :batch_insert, :start | :stop | :exception]
[:gf, :epoch,   :boundary]
```

**Why:**

Customer agent spans arrive as OTLP JSON over HTTP and are routed into per-session `GenServer`s. They are stored in the Ledger. If we also re-emitted them as `:telemetry` events, every customer would inherit our internal handlers (loggers, Prometheus exporters), and every handler crash would risk a back-pressure cascade into the ingestion path.

The boundary is intentional: `:telemetry` measures GhostFactory; the Ledger measures the customer's agents. They never cross.

**Operational consequence:** `GfExperiment.Ingestion.TelemetryLogger.attach/0` is safe to enable in development — it only logs the `[:gf, ...]` namespace.

---

## References

- Linear: [ADR-001 — Architecture decisions and the layered model](https://linear.app/gf-aos/document/adr-001-architektonicka-rozhodnuti-a-vrstvovy-model-85ee2435485f)
- Code: `lib/gf_experiment/ledger.ex`, `lib/gf_experiment/ingestion/session_gen_server.ex`
- Related docs: `docs/payload-schemas.md`, `docs/development.md`
