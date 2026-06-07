<!-- Source: architecture-map.md §8 — Test architektura -->

## 8. Test architektura — jak testujeme OTP

### `assert_receive` místo `Process.sleep`

`Process.sleep(N)` v testech je anti-pattern: buď je N moc krátké
(flaky test) nebo moc dlouhé (suite pomalý). `assert_receive` čeká
deterministicky na konkrétní zprávu s timeout fallbackem.

**Kdy `assert_receive` nestačí**:
1. Když čekáš na DB row visibility a broadcast firi UVNITŘ DB transakce
   (pre-GF-703 telemetry race). `assert_receive` na telemetry event tě
   probudí, ale `Repo.all` ještě nevidí commit. Fix: GF-703 přesunul
   broadcast PO `Repo.transaction` return.
2. Když očekáváš násobné broadcasty (multi-batch wait) — `assert_receive` čeká
   na první. Pak musíš count check (`Cassettes.Replayer.wait_for_all_spans/3`).
3. Když test process subscribuje až PO callee, který v `after` bloku
   unsubscribuje — `Registry.unregister` smaže VŠECHNY subscriptions caller
   PID na topic. Subscribe order matters (CLAUDE.md L#96, `replayer_test.exs:130`).

### Broadway telemetry barrier pattern (CLAUDE.md L#94)

Klasická past: testy POSTují `/ingest` nebo volají `SGS.ingest_spans/2`,
pak assertují row v DB. Bez barrier:
- Broadway batch v jiném procesu (Sandbox owned by test) ještě nedoběhl →
  `Repo.all` vrátí prázdno.
- Test skončí → ExUnit checkin Sandbox → Broadway dokončí transakci na
  released connection → `Exqlite.Connection ConnectionError "owner exited"`.

**Pattern (post-GF-703)**:
```elixir
Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")    # BEFORE ingest!
:ok = SGS.ingest_spans(run_id, spans)
assert_receive {:spans_flushed, ^run_id}, 5_000                   # waits for Repo.transaction commit
# now Repo.all is safe
```

Pre-GF-703 používali telemetry `[:gf, :ledger, :batch_insert, :stop]` —
firi UVNITŘ transakce → race s commit. GF-703 přesunul broadcast PO transakci,
nový pattern v `session_gen_server_test.exs:25-37` (`wait_for_all_committed/3`).

### `broadway_producer_module` config injection (proč ne Mox)

Broadway nepřijímá callbacky na producer types — producer je child spec uvnitř
Broadway supervision tree, instantiovaný v `Broadway.start_link`. Mox by neměl
kde injectovat — nemůžeš `Mox.defmock(BufferProducerMock)` a pak Broadway
říct „použij Mock". Místo toho:

`config :span_chain, :broadway_producer_module, ProducerModule` (`config.exs:7`)
→ `Pipeline.start_link/1` (`pipeline.ex:37-38`) čte runtime: `Application.fetch_env!(:span_chain, :broadway_producer_module)`.

Test env (`config/test.exs:20`) ponechává reálný `BufferProducer` — SGS →
producer → Broadway → DB end-to-end. Trade-off: `Broadway.test_message/3` nelze
(vyžaduje `Broadway.DummyProducer`); pro negativní Pipeline testy se používá
přímý `BufferProducer.enqueue` + telemetry/PubSub barrier.

Stejný DI pattern: `:ledger_module` a `:dead_letter_module` (`pipeline.ex:74,151`)
— testy nahradí Mock modulem přes `Application.put_env` + `on_exit` restore
(`pipeline_negative_test.exs` pattern).

### Property testy (StreamData)

`test/span_chain/ledger_property_test.exs` — co testujeme a proč:

- **Property D: tamper detection** — pro libovolný payload list, tamper
  payload na index `i`, recomputed hash MUSÍ differ. Generátor je `list_of`
  `map_of` strings, ne fixed examples — pokrývá HAMT-sized maps (>32 keys)
  i prázdné mapy. Toto je vlastní integrity invariant Ledgeru, testovaný
  generativně místo cherry-picked.
- **Property D2: deterministická chain construction** — identický payload na
  identické pozici → identický hash. Catches HAMT order non-determinism
  pre-GF-654 (a regrese kdyby někdo přepsal canonical_encode).

Proč property testy právě tu: chain integrity je **single source of truth**
celého systému. Unit test pokryje known examples; property test pokryje
adversarial input space. Selhání property testu po commitu = okamžitý
red flag.

Další property file: `payload_serializer_property_test.exs` — invariant
`canonical_encode(a) == canonical_encode(a)` pro libovolnou mapu, JSON
roundtrip přes Jason je validní.

---

