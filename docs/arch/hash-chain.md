<!-- Source: architecture-map.md §5 — Hash-chain invariant -->

## 5. Hash-chain invariant — how it works and why

### What a hash-chain is

Each record in `ledger_entries` has the columns:

- `seq` — sequence number within the epoch (0..999)
- `epoch_id` — epoch sequence number (0, 1, 2, ...)
- `prev_hash` — hash of the previous record (NULL for the very first)
- `hash` — SHA256 hex of this record
- `event_type` — string discriminator ("llm_call", "tool_call", ...)
- `parent_span_id` — for the span tree hierarchy
- `payload` — an opaque JSON map with the whole span
- + projection columns `span_id`, `trace_id`, `started_at`, `ended_at`, `status` (GF-669/GF-653/GF-790, **NOT** in the hash)

### What goes into the hash

From `compute_hash/7` in `ledger.ex` (post GF-787):

```elixir
data =
  "#{Integer.to_string(seq)}:#{prev_hash || "nil"}:#{event_type}:" <>
    "#{canonical_encode(payload)}:#{parent_span_id || "nil"}:#{run_id}:#{Integer.to_string(epoch_id)}"
:crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
```

Order: `seq`, `prev_hash`, `event_type`, `canonical_encode(payload)`,
`parent_span_id`, `run_id`, `epoch_id`. **Seven fields**, separator `:`. `nil` is hashed
as the literal `"nil"` — deliberately, so NULL is deterministic. The integer fields (`seq`,
`epoch_id`) go into the string via an explicit `Integer.to_string/1` (GF-812 — in
cryptographic code every conversion must be deliberate, not delegated to `String.Chars`
protocol dispatch; the output is bit-for-bit identical, pinned regression test in `ledger_test.exs`).

**`run_id` + `epoch_id` ARE in the hash (GF-787)** — an entry is thus cryptographically bound
to its run/epoch, not just by the SQL filter in `verify_ledger` (`where run_id == ^x`). Before
(5 fields, pre-GF-787) an entry could be silently moved under a different `run_id`/`epoch_id` in the DB without
detection; now that breaks the chain. **Scope (honestly):** it closes naive SQL relabel/move;
the hash stays *unkeyed* → an attacker with DB write + recompute can still forge a clean chain and
tail truncation is invisible (keyed/HMAC + external anchoring = future work).

### Why `canonical_encode`

`payload_serializer.ex:14-24`: Elixir maps with >32 keys switch to a HAMT
representation that does NOT GUARANTEE key order on iteration. `Jason.encode!(map)`
can therefore return different JSON strings for identical data depending on insertion
order. That would cause a false `{:error, :chain_broken}` on runs with large
payloads. `canonical_encode` serializes recursively with a lexical sort of keys
directly over a list of 2-tuples — key order is deterministically stable.
GF-654 was introduced exactly for this. The pitfall the prompt mentions: `Map.new`
after the sort immediately LOSES the key order (the map re-hashes the keys) — so we
build the JSON string by hand.

### `verify_ledger/1` — what it does

From `ledger.ex:181-205`:

```elixir
entries = (from l in Ledger, where l.run_id == ^run_id, order_by [asc: :epoch_id, asc: :seq])
Enum.reduce_while(entries, {:ok, 0, nil}, fn e, {:ok, count, last_hash} ->
  expected = compute_hash(e.seq, e.prev_hash, e.event_type, e.payload, e.parent_span_id, e.run_id, e.epoch_id)
  cond do
    e.prev_hash != last_hash  -> {:halt, {:error, :chain_broken}}     # gap detection
    expected != e.hash         -> {:halt, {:error, :chain_broken}}     # tamper detection
    true                       -> {:cont, {:ok, count + 1, e.hash}}    # advance
  end
end)
```

The function recomputes the hash of each row and compares:
1. **Tamper**: `expected != e.hash` — someone overwrote `payload`/`event_type`/`parent_span_id` in the DB but didn't recompute `hash`. SHA256 detects it.
2. **Gap**: `e.prev_hash != last_hash` — a row is missing in the middle (dead-letter / DELETE). Record `n+1` has `prev_hash = hash(n)`, but in the reduce we already skipped `n`, so `last_hash` doesn't match.

### When `{:error, :chain_broken}` happens in practice

| Situation | Reason for chain_broken |
|---|---|
| **Dead-letter** | A batch failed after 3 retries → `DeadLetter.store/3` → the row doesn't exist in the Ledger. The hash chain continues (the SGS incremented `seq`/`prev_hash` anyway), but the gap is detected. A deliberate audit signal "data exists, but not in authoritative source." (`dead_letter.ex:1-15` › "not part of the hash-chain... `verify_ledger` fails — that is intentional") |
| **Tamper** | A manual `Repo.update_all` on the payload/parent_span_id column. Smoke test shown in development.md:81-91. |
| **Race in Pipeline retry** | If a retry succeeds but the insert is duplicate → the unique index `(run_id, epoch_id, seq)` → idempotent skip. NOT chain_broken — `on_conflict: :nothing` in `ledger.ex:148-150`. |
| **Epoch Island Attack** | Someone deletes a whole epoch (e.g. all rows for `epoch_id = 5`). The first row of epoch 6 has `prev_hash = hash(last_row_of_epoch_5)`, but `last_hash` in the reduce is `hash(last_row_of_epoch_4)`. → `chain_broken`. **THIS IS EXACTLY WHAT GF-666 ADDED.** |

### Epoch boundary — why it exists and what the "Epoch Island Attack" is

`session_gen_server.ex:175-186`:

```elixir
defp maybe_epoch_boundary(%{seq: seq} = state) when seq > 0 and rem(seq, @epoch_size) == 0 do
  :telemetry.execute([:gf, :epoch, :boundary], ...)
  %{state | epoch_id: state.epoch_id + 1, seq: 0, prev_hash: state.prev_hash}
end
```

Every `@epoch_size = 1_000` spans (`session_gen_server.ex:41`) the epoch
rolls over: `epoch_id++`, `seq=0`. Reason: the index on `(run_id, epoch_id, seq)` has
a bounded space — without epochs `seq` would grow without bound and operations over the chain
(verify, range queries) would slow down linearly with the length of the run.

**Key GF-666 fix**: `prev_hash: state.prev_hash` — the hash of the LAST record
of the previous epoch is PRESERVED as the `prev_hash` of the FIRST record of the new epoch.
Without it, each epoch would start with `prev_hash = nil` and verify_ledger would be
blind to the deletion of a whole epoch (pre-GF-666 bug: "Epoch Island Attack" —
an adversary deletes `epoch_id = N`, epoch N+1 starts with a nil-prev_hash, it looks
like a legitimate start, the integrity check passes).

Pre-GF-666: `verify_ledger` reset `last_hash` at the epoch boundary
→ the island went undetected. Post-GF-666: `last_hash` carries across epochs
in the reduce loop (`ledger.ex:190-199`) → `entry.prev_hash != last_hash` at the
first record of epoch N+1 → `{:error, :chain_broken}`. ✅

---

