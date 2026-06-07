# ADR-003 — SGS Crash Recovery: Race-Safe Design

**Datum:** 2026-05-26 (implementováno 2026-05-27)
**Status:** IMPLEMENTED (commit `4a3f8b2`)
**Issue:** GF-775
**Autoři:** Jiří Joneš + Gemini + Grok (třímodelový review Sprint 11)

---

## Kontext

`SessionGenServer` (SGS) drží hash-chain state (`prev_hash`, `seq`, `epoch_id`)
v paměti. Po OTP crash → auto-restart startuje `init/1` s prázdným stavem
(`seq: 0`, `prev_hash: nil`). Výsledek: corrupted hash-chain pro daný `run_id`.

GF-768 audit potvrdil: `verify_ledger/1` po crash → restart → ingest vrátí
`{:error, :chain_broken}`. Test v `session_gen_server_test.exs` toto explicitně
assertuje (komentář: flip na `{:ok, _}` až toto ADR bude implementováno).

### Proč naivní fix nefunguje

**Varianta A: Repo read v `init/1` nebo `handle_continue`**
- Porušuje hard rule z CLAUDE.md: "Nepřidávej žádné Repo. volání do
  SessionGenServer" (GF-751 — záměrné architektonické rozhodnutí)
- Async race: `BufferProducer` přežívá SGS crash. In-flight spany se flushnou
  po restartu SGS. Recovery read by četl stale DB pozici → kolize.

**Varianta B: Naivní supervisor-level recovery bez drain**
- `ensure_session/1` čte poslední pozici z DB, předává do SGS
- Stale read problém zůstává — in-flight spany ještě v DB nejsou v momentě
  recovery read.

---

## Rozhodnutí

**Epoch rollover + supervisor-level recovery + drain signal**

### Mechanismus

#### 0. SGS `restart: :temporary` (enabler)

> **Implementační korekce oproti původnímu návrhu.** Recovery v
> `ensure_session/1` se spustí jen když je Registry prázdný. SGS byl ale
> `:permanent` DynamicSupervisor child → supervisor ho po crashi auto-restartoval
> se stale stavem (`epoch 0`, `prev_hash: nil`) JEŠTĚ PŘED dalším
> `ensure_session/1` voláním → recovery se nikdy nespustila. SGS je proto nyní
> `use GenServer, restart: :temporary`: crashnutý SGS se neauto-restartuje,
> Registry se vyprázdní a další ingest přes `ensure_session/1` provede recovery.
> Crashnutý run má in-memory kurzor down do dalšího spanu (data jsou bezpečně
> v DB).

#### 1. Epoch rollover při každém SGS restartu

Každý restart SGS navýší `epoch_id`. Stará epocha je uzavřena.

```elixir
# V SessionSupervisor.ensure_session/1 při detekci restartu (Registry prázdný,
# run je v DB). Repo read žije VÝHRADNĚ zde (GF-751):
last_epoch = fetch_last_epoch(run_id)          # max(epoch_id) z DB
await_epoch_drain(run_id, last_epoch)          # viz #2
prev_hash = fetch_last_hash(run_id)            # poslední commitnutý hash (po drainu)
spawn_session(run_id, epoch_id: last_epoch + 1, prev_hash: prev_hash)
```

Epoch rollover eliminuje kolizi mezi starými (in-flight) a novými spany —
různé `epoch_id` → různý sekvence prostor → `on_conflict: :nothing` na
`(run_id, epoch_id, seq)` nikdy nebude kolidovat.

> **Implementační korekce: `prev_hash` se NESE z DB, NE `nil`.** Původní návrh
> startoval novou epochu s `prev_hash: nil`. To by ale samo bylo
> `{:error, :chain_broken}`: `verify_ledger/1` vynucuje GF-666 cross-epoch
> kontinuitu (iteruje `(epoch_id ASC, seq ASC)` lineárně a nese `last_hash` přes
> epoch hranice; `prev_hash: nil` je povolen JEN pro úplně první záznam
> `epoch 0, seq 0`). `ensure_session/1` proto přečte poslední commitnutý hash a
> předá ho jako `prev_hash` nové epochy. Tím zůstává `verify_ledger/1` **beze
> změny** a zachová se Island Attack detekce (smazání celé epochy uprostřed =
> `chain_broken`). Alternativa "segmentovat `verify_ledger` per epocha" byla
> zamítnuta — regreduje GF-666.

#### 2. In-flight drain před novým ingestem

Po crashi SGS existuje okno kdy `BufferProducer`/Broadway může stále commitovat
staré spany. `ensure_session/1` čeká na drain signal PŘED čtením posledního hashe.

```elixir
# V ensure_session/1, před fetch_last_hash:
await_epoch_drain(run_id, old_epoch_id)
# subscribe "epoch_flush:#{run_id}", receive {:epoch_flushed, run_id, old_epoch_id}
# nebo timeout (default 1_200ms = batch_timeout + buffer, seam :epoch_drain_timeout_ms) — pak bez záruky.
# Symetrický un/subscribe v každé exit path.

# Pipeline.handle_batch broadcastuje po KAŽDÉM úspěšném commitu, jeden signal
# per unikátní {run_id, epoch_id} v dávce (crash-safe, jako safe_broadcast/1):
Phoenix.PubSub.broadcast(GfExperiment.PubSub,
  "epoch_flush:#{run_id}",
  {:epoch_flushed, run_id, epoch_id}
)
```

#### 3. SGS zůstává Repo-free

SGS nedělá žádné Repo volání — zachovává GF-751 invariant. Stav (`epoch_id`,
`prev_hash`, `seq`) dostane jako parameter při startu od supervisoru
(`start_link/1` opts: `epoch_id` default 0, `prev_hash` default nil).

### Prerekvizita: Postgres (GF-704) ✅

Na SQLite byl drain timeout spolehlivý jen při low load. Na Postgresu je
read-after-write po commitu garantován (MVCC), takže jakmile `ensure_session/1`
obdrží `{:epoch_flushed}`, daná dávka JE viditelná. GF-704 i GF-779 (partition_by)
jsou merged; GF-775 implementováno po nich.

---

## Alternativy které byly zamítnuty

| Alternativa | Důvod zamítnutí |
|---|---|
| Repo read v SGS `handle_continue` | Porušuje CLAUDE.md/GF-751 invariant |
| Snížit `batch_timeout` pro rychlejší drain | Zhorší throughput, SQLITE_BUSY risk |
| Persistent queue (NATS) pro BufferProducer | L3 scope — přesahuje L2 fázi |
| Deploy bez crash recovery | Audit trail produkt nemůže mít dokumentovaný `:chain_broken` scénář |

---

## Dopad na kód

| Soubor | Změna |
|---|---|
| `lib/gf_experiment/ingestion/session_gen_server.ex` | `restart: :temporary`; `start_link`/`init` přijímají `epoch_id` + `prev_hash` (defaulty 0 / nil). Stále 0× `Repo.` (GF-751) |
| `lib/gf_experiment/ingestion/session_supervisor.ex` | Recovery v `ensure_session/1`: `fetch_last_epoch` / `await_epoch_drain` / `fetch_last_hash` (Repo reads VÝHRADNĚ zde) |
| `lib/gf_experiment/ingestion/pipeline.ex` | `handle_batch` broadcastuje `{:epoch_flushed, run_id, epoch_id}` per unikátní `{run_id, epoch_id}` po commitu |
| `test/gf_experiment/ingestion/session_gen_server_test.exs` | Crash recovery test přepsán: žádný auto-restart, recovery přes `ensure_session`, assert `{:ok, 11}` |
| `test/gf_experiment/ingestion/session_supervisor_test.exs` | → `DataCase` (`ensure_session` teď čte DB → potřebuje sandbox) |

`verify_ledger/1` — **beze změny**. Kontinuita je zachována tím, že nová epocha
**nese `prev_hash` z DB** (ne segmentací `verify_ledger` per epocha) — GF-666
cross-epoch kontinuita i Island Attack detekce zůstávají platné.

---

## Známá omezení

- **Multi-batch drain — VYŘEŠENO (GF-782, commit `e5df46f`).** Původně `await_epoch_drain`
  vracel po PRVNÍM `{:epoch_flushed}`; při burstu > `batch_size` (50) bylo více in-flight batchů →
  `fetch_last_hash` četl stale pozici → `prev_hash` nové epochy na nefinální hash →
  `verify_ledger/1` `{:error, :chain_broken}`. GF-780 to jen zúžil časově (timeout 500→1_200ms).
  GF-782 to řeší strukturálně: `drain_until_silence/3` po prvním flush drainuje dokud nepřijde
  `silence_ms` ticha (ne jen jednu zprávu) → pokryje libovolný počet in-flight batchů. Seam
  `epoch_drain_silence_ms` (default 200ms = 2× prod `batch_timeout` 100ms; `config/test.exs`: 75ms
  > 50ms test batch_timeout). Outer `epoch_drain_timeout_ms` (1_200ms) zůstává cold/fast-path guard
  (Broadway commitne vše před `subscribe` → timeout vrátí `:ok`, data committed).
- **Crashnutý run zůstává bez in-memory kurzoru** do dalšího spanu (důsledek
  `restart: :temporary`). Data jsou v DB; kurzor se rebuildne při dalším ingestu.

## Done When

- ✅ `verify_ledger/1` vrátí `{:ok, _}` po scénáři 5 spanů → kill SGS → recovery
  přes `ensure_session/1` → 6 spanů (test assertuje `{:ok, 11}`; epoch 0 + epoch 1).
- ✅ Crash recovery test přepsán (žádný `:chain_broken` v `session_gen_server_test.exs`).
- ✅ `grep "Repo\." lib/gf_experiment/ingestion/session_gen_server.ex` → 0 hitů.
- ✅ GF-704 (Postgres) + GF-779 (partition_by) merged před implementací.
- ✅ `mix test` → 157 testů, 0 failures (Postgres).

---

*ADR-003 · Status: IMPLEMENTED (GF-775, commit `4a3f8b2`; drain timeout tuning GF-780, commit `e65d608`; multi-batch drain-until-silence GF-782, commit `e5df46f`) · Linear: [ADR-003 dokument](https://linear.app/gf-aos/document/adr-003-sgs-crash-recovery-race-safe-design-f125e9c385a3)*
