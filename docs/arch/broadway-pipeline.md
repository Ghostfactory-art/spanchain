<!-- Source: architecture-map.md §6 — Broadway -->

## 6. Broadway — proč tady a jak funguje

### Problém: HTTP Acceptor Exhaustion (pre-GF-667)

Před GF-667 SGS sám voláním `Ledger.insert_batch` synchronně. Pod stress
testem se 100+ konkurenty docházelo k:

1. SGS volá `Ledger.insert_batch` ve `handle_call` (blokuje SGS).
2. SQLite single-writer drží lock → ostatní inserts čekají na `SQLITE_BUSY`.
3. Bandit acceptor pool má omezený počet procesů. Každý HTTP request si bere
   acceptor → ten volá `SGS.ingest_spans/2` synchronně (`GenServer.call`) →
   čeká až SGS dokončí DB insert.
4. Při dostatečné zátěži všichni acceptori blokují → nové requesty se
   zařadí do TCP accept queue → eventuálně reset.

GF-667 vyřešil: **separace synchronní hash computation (rychlá, ~50 µs) od
asynchronní DB persistence** přes Broadway pipeline. SGS po `build_entries`
okamžitě castne do BufferProducer a vrátí 202. DB write se děje na pozadí.

### Broadway producer/consumer model

```
BufferProducer (GenStage :producer)            Pipeline (Broadway consumer)
─────────────────────────────────              ─────────────────────────────
state: %{queue: :queue, demand: N}             Processor.handle_message (passthrough)
                                                          ↓
SGS.cast {:enqueue, entries}                   Batcher (50 / 1000ms)
  → enqueue do queue                                      ↓
  → dispatch/1: emit min(queue, demand)        handle_batch/4
                                                 → Repo.transaction(insert_batch)
                                                 → with_retry 3× exp backoff
                                                 → broadcast OR DeadLetter
```

**Demand model (pull)** — kritický rozdíl od push fronty:

1. Producer NEemituje messages dokud Processor neřekne „pošli mi N zpráv".
2. Processor request demand jen když má volnou kapacitu (po dokončení batch).
3. Pokud queue ≥ demand → emit N a vyčisti demand counter.
4. Pokud queue < demand → emit co máš, ulož zbývající demand (`state.demand`).
5. Když přijde nový enqueue cast → znovu volej dispatch.

Implementace v `buffer_producer.ex:90-109`. Žádný overload — když SGS castuje
rychleji než SQLite zvládá insertovat, queue roste v paměti (in-memory `:queue`,
ne ETS, ne disk). Pro L2 to je akceptovatelné; L3 přejde na persistent queue
(NATS JetStream, GF-648).

### Proč `rest_for_one` a co by se stalo s `one_for_one`

Z `application.ex:31-40` a `development.md:295-332`:

PipelineSupervisor obaluje `[BufferRegistry, Pipeline]` strategií `:rest_for_one`.
Pořadí dětí MUSÍ být tohle — `rest_for_one` při crashi dítěte X restartuje
JEN dítě X **a všechna další za ním**, předchozí necháno běžet.

**Scénář s `one_for_one` (nesprávný)**:
1. BufferRegistry crash.
2. `one_for_one` ho restartne → fresh ETS table, bez registrací.
3. BufferProducer žije UVNITŘ Broadway tree (ne přímo pod PipelineSupervisor),
   takže není restartován.
4. BufferProducer `init/1` se NEVOLÁ znovu (init se volá jen při spawnu).
5. Žádná self-re-registrace v fresh BufferRegistry → `Registry.lookup(:singleton)` vrátí `[]`.
6. `SGS.enqueue/1` vrací `{:error, :no_producer}`. Tiché ztráty.

**Scénář s `rest_for_one` (správný)**:
1. BufferRegistry crash.
2. `rest_for_one` restartne Registry **AND** vše za ním → Pipeline restart.
3. Pipeline restart kaskáduje na Broadway internals → Broadway respawn BufferProducer.
4. Nový BufferProducer.init/1 se VOLÁ → `Registry.register(BufferRegistry, :singleton, nil)` → re-registrace v fresh Registry.
5. SGS lookups okamžitě fungují.

**Proč scope `PipelineSupervisor` jen na 2 děti, ne root jako `rest_for_one`**:
Kdyby root byl `rest_for_one`, crash čehokoliv v ingestion (SessionSupervisor,
PipelineSupervisor, Bandit, ...) by strhl vše za ním (PubSub, Phoenix Endpoint).
Blast radius je záměrně malý — pouze `[BufferRegistry, Pipeline]`. Vyšší
úrovně root `one_for_one` izoluje.

**Známý edge case GF-724** (`development.md:362-380`): `Process.exit(reg, :kill)`
přímo na BufferRegistry supervisor exploduje root supervisor kvůli ETS name
race. Synthetic test only — v produkci Registry partition self-recovers bez
externího kill. L3 followup: GF-729.

### Concurrency (GF-779, post-Postgres GF-704)

`pipeline.ex` Broadway opts:
- Producer: 1 (singleton, BufferRegistry závisí na unique key) — beze změny
- Processors: `System.schedulers_online()` (prod/dev) / 1 (test seam)
- Batchers: 4 + `partition_by: fn msg -> :erlang.phash2(msg.data.run_id) end` (prod/dev) / 1 (test)

Postgres MVCC umožňuje souběžné `insert_all`. `partition_by` MUSÍ hashovat
(`:erlang.phash2`) — Broadway počítá `rem(func.(msg), concurrency)`, bare string
`run_id` by spadl na `ArithmeticError`. Stejný run_id → stejná batcher partition
(per-session serializace), různé run_ids paralelně. Test env pinováno na 1 přes
seamy `broadway_processor_concurrency` / `broadway_batcher_concurrency`.

### Retry sémantika

`pipeline.ex:197-224` — 3 pokusy, exp backoff `500 → 1000 → 2000 ms` v prod
(test override 1ms, drží negativní testy pod 50ms). Po vyčerpání:
`Message.failed/2` → `handle_failed/2` → `DeadLetter.store/3`. Hash chain
v Ledger pokračuje bez chybějících rows (SGS `prev_hash` zůstává advanced) →
`verify_ledger` to vrátí jako `chain_broken` — záměrný audit signál.

---

