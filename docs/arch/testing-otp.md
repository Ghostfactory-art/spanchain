<!-- Source: architecture-map.md §8 — Test architecture -->

## 8. Test architecture — how we test OTP

### `assert_receive` instead of `Process.sleep`

`Process.sleep(N)` in tests is an anti-pattern: either N is too short
(flaky test) or too long (slow suite). `assert_receive` waits
deterministically for a specific message with a timeout fallback.

**When `assert_receive` is not enough**:
1. When you wait for DB row visibility and the broadcast fires INSIDE the DB transaction
   (pre-GF-703 telemetry race). `assert_receive` on the telemetry event wakes
   you, but `Repo.all` doesn't see the commit yet. Fix: GF-703 moved the
   broadcast AFTER the `Repo.transaction` return.
2. When you expect multiple broadcasts (multi-batch wait) — `assert_receive` waits
   for the first. Then you need a count check (`Cassettes.Replayer.wait_for_all_spans/3`).
3. When the test process subscribes only AFTER a callee that unsubscribes in its `after`
   block — `Registry.unregister` deletes ALL of the caller PID's subscriptions
   on the topic. Subscribe order matters (CLAUDE.md L#96, `replayer_test.exs:130`).

### Broadway telemetry barrier pattern (CLAUDE.md L#94)

The classic pitfall: tests POST `/ingest` or call `SGS.ingest_spans/2`,
then assert a row in the DB. Without a barrier:
- The Broadway batch in another process (Sandbox owned by the test) hasn't finished yet →
  `Repo.all` returns empty.
- The test ends → ExUnit checks in the Sandbox → Broadway finishes the transaction on a
  released connection → `Exqlite.Connection ConnectionError "owner exited"`.

**Pattern (post-GF-703)**:
```elixir
Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")    # BEFORE ingest!
:ok = SGS.ingest_spans(run_id, spans)
assert_receive {:spans_flushed, ^run_id}, 5_000                   # waits for Repo.transaction commit
# now Repo.all is safe
```

Pre-GF-703 used the telemetry `[:gf, :ledger, :batch_insert, :stop]` —
fires INSIDE the transaction → races with the commit. GF-703 moved the broadcast AFTER the transaction;
the new pattern is in `session_gen_server_test.exs:25-37` (`wait_for_all_committed/3`).

### `broadway_producer_module` config injection (why not Mox)

Broadway does not accept callbacks for producer types — the producer is a child spec inside
the Broadway supervision tree, instantiated in `Broadway.start_link`. Mox would have
nowhere to inject — you can't `Mox.defmock(BufferProducerMock)` and then tell Broadway
to "use the Mock". Instead:

`config :span_chain, :broadway_producer_module, ProducerModule` (`config.exs:7`)
→ `Pipeline.start_link/1` (`pipeline.ex:37-38`) reads it at runtime: `Application.fetch_env!(:span_chain, :broadway_producer_module)`.

The test env (`config/test.exs:20`) keeps the real `BufferProducer` — SGS →
producer → Broadway → DB end-to-end. Trade-off: `Broadway.test_message/3` isn't possible
(it requires `Broadway.DummyProducer`); for negative Pipeline tests we use a
direct `BufferProducer.enqueue` + telemetry/PubSub barrier.

Same DI pattern: `:ledger_module` and `:dead_letter_module` (`pipeline.ex:74,151`)
— tests replace it with a Mock module via `Application.put_env` + `on_exit` restore
(the `pipeline_negative_test.exs` pattern).

### Property tests (StreamData)

`test/span_chain/ledger_property_test.exs` — what we test and why:

- **Property D: tamper detection** — for an arbitrary payload list, tamper
  the payload at index `i`, the recomputed hash MUST differ. The generator is `list_of`
  `map_of` strings, not fixed examples — it covers HAMT-sized maps (>32 keys)
  and empty maps. This is the Ledger's own integrity invariant, tested
  generatively instead of cherry-picked.
- **Property D2: deterministic chain construction** — an identical payload at an
  identical position → an identical hash. Catches HAMT order non-determinism
  pre-GF-654 (and a regression if someone rewrote canonical_encode).

Why property tests right here: chain integrity is the **single source of truth**
of the whole system. A unit test covers known examples; a property test covers
the adversarial input space. A property-test failure after a commit = an immediate
red flag.

Another property file: `payload_serializer_property_test.exs` — the invariant
`canonical_encode(a) == canonical_encode(a)` for any map, and that the JSON
roundtrip via Jason is valid.

---

