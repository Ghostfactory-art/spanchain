<!-- Source: architecture-map.md §7 — Eval + Replay systém -->

## 7. Eval + Replay systém

### Eval Framework (GF-706, GF-707)

`Eval` je zastřešující agregát pro porovnávání více `runs` se stejným záměrem.
Use case: „stejná otázka, 3 různé modely → který je nejlepší?"

**Datový model**:
- `evals` tabulka (`eval.ex`): `eval_id` PK, `name`, `description`, `status`
- `runs.eval_id` FK (`run.ex:26`): nullable, belongs_to Eval s `references: :eval_id`

**Jak `gf.eval_id` přichází přes OTLP**:

Klient v requestu na `/v1/traces` zadá:
```json
{"resourceSpans":[{"resource":{"attributes":[
  {"key":"service.instance.id","value":{"stringValue":"run-fast"}},
  {"key":"gf.eval_id","value":{"stringValue":"eval-llm-v1"}}
]}, ...}]}
```

`OtlpTranslator.extract_eval_id/1` (`otlp_translator.ex:73-80`) ho extrahuje
jako string nebo `nil`. `Router.handle_otlp/1` (`router.ex:88-91`) předá do
`SessionSupervisor.ensure_session(run_id, eval_id: eval_id)` — **NE přes
`ingest_spans/2` signature** (zachovává backward compat pro `/ingest` JSON,
viz CLAUDE.md „Do NOT").

**Po GF-751/GF-746 (commit `9c7f03c`)** je passive associace plně přesunutá
do Broadway pipeline. `SGS.init/1` (`session_gen_server.ex:120-122`) je nyní
**no-op DB-wise** — jen postaví in-memory state. Per-call `eval_id` (z OTLP
resource attrs nebo GF-727 late-binding přes `ingest_spans/3` opts) žije
v `state.eval_id` a `append_span/2` ho přilepí k entry jako in-memory
`:eval_id` sidecar (NE Ledger schema field).

**Pipeline.handle_batch/4** (`pipeline.ex:72-130`) potom:

```
ensure_run_records(entries)
  → Repo.insert_all("runs", uniq_by(run_id),
      on_conflict: :nothing, conflict_target: [:run_id])

ensure_eval_records(entries)
  → Repo.insert_all("evals", uniq_by(eval_id), ...)            # FK target PRVNÍ
  → from(r in Run, where: r.run_id == ^entry.run_id,
         update: [set: [eval_id: fragment("COALESCE(eval_id, ?)", ?)]])
    |> Repo.update_all([])                                     # COALESCE first-wins

upsert_agent_configs(entries)  # GF-748 gf.agent.*

# strip :eval_id sidecar PŘED Ledger schema insert:
ledger_entries = Enum.map(entries, &Map.delete(&1, :eval_id))
with_retry → Repo.transaction → Ledger.insert_batch(ledger_entries)
broadcast_flushed(entries)
```

**FK pořadí ZACHOVÁNO:** Eval insert v `ensure_eval_records` PRVNÍ (PK pro
`runs.eval_id` FK), `Run.eval_id` COALESCE update DRUHÝ. Veškerá failure
v metadata fázích NEKRESHNE Pipeline — defensive `rescue` + `catch` kolem
každé funkce (per CLAUDE.md "observability nesmí blokovat ingesci dat").

**Sémantický posun:** `Run`/`Eval` řádky vznikají AŽ po prvním Broadway
flush (batch_timeout 50ms test / 1000ms prod), ne na SGS spawn-time.
Pro `/trail` LiveView (read-only post-facto inspection) neviditelné.
Testy assertující synchronní DB visibility po `ingest_spans` musí použít
`wait_for_all_committed/2` před DB asserty — viz GF-727 test fixy.

### Comparator (pure tree diff)

`evals/comparator.ex:1-22` › „Pure logika — žádný GenServer, žádný stav.
Repo.all jako jediný side effect (deterministic pro daný DB snapshot)."

**Algoritmus**:
1. `load_run(run_id)` (`comparator.ex:51-66`) — fetch Ledger rows ORDER BY epoch_id, seq + `build_tree`.
2. `build_tree/1` (`comparator.ex:69-79`) — group by `parent_span_id`, attach recursively. Identický algoritmus jako `TrailLive.build_tree/1` (`trail_live.ex:298-307`); zkopírovaný komentář v Comparator přiznává.
3. `pair_by_name/2` (`comparator.ex:159-183`) — pro každé jméno spáruj i-tý A s i-tým B (sibling position). `Enum.uniq` na klíčích zachovává insertion order kvůli stabilnímu `deviation_point`.
4. Generování diff entries:
   - `{:only_a, node}` → `"span_removed"`
   - `{:only_b, node}` → `"span_added"`
   - `{:both, a, b}` → `duration_diff_entry` (>20% threshold v `@duration_threshold` na řádku 28) + recurse children
5. `mark_deviation_points/1` (`comparator.ex:234-237`) — volaná per top-level branch uvnitř `diff_trees/2` (`comparator.ex:153` flat_map), označí první diff entry v listu argumentu. Per-branch chování pochází z call site; GF-740 (Sprint 7, commit `aabb26b`) fix od pre-GF-740 global-index-0 chování.

**Edge cases**:
- Both `eval_id` nil → `:ok` (OK porovnat unassigned runs)
- A.eval_id = "x", B.eval_id = "x" → `:ok`
- A.eval_id = "x", B.eval_id = "y" → `{:error, :different_eval}` (`comparator.ex:85-87`)
- Run neexistuje → `{:error, :run_not_found}` (`comparator.ex:52-53`)

**Duration computation** (`comparator.ex:209-234`): **payload first**, projekce
fallback. GF-669 projekční sloupce `started_at`/`ended_at` jsou truncated na
`:second` (`ledger.ex:117`), takže sub-second durations dají 0. Payload uchovává
ISO8601 strings s ms precision. Lesson learned z GF-706.

**Konzumenti Comparator**:
- `Evals.compare/2` defdelegate (`evals.ex:38`) → HTTP `GET /evals/:id/compare`
- `Web.EvalLive` přímo (`eval_live.ex:35`) — same OTP app, HTTP hop by byl zbytečný
- `Cassettes.Replayer` (`replayer.ex:48-52`) — diff replay vs source

### VCR Cassettes (GF-712)

`Cassettes.record/2` (`cassettes.ex:14-43`):
1. Load všechny `payload` rows pro `run_id` ORDER BY epoch_id, seq (`load_payloads/1`).
2. Insert `%Cassette{}` s `snapshot: [payload, payload, ...]` (array of maps).
3. PAYLOAD-FIRST: ukládáme raw `payload` mapu, NE projekční sloupce. (Lesson z GF-706 sub-second precision bug.)

`Cassettes.Replayer.replay/2` (`replayer.ex:31-59`) — **pure module**, ne GenServer:
1. Subscribe na `"run:#{new_run_id}"` **PŘED** ingest (jinak ztratíš první broadcasty).
2. `SessionSupervisor.ensure_session(new_run_id)` + `SGS.ingest_spans(new_run_id, spans)`.
3. **Multi-batch wait** — receive loop `{:spans_flushed, ^run_id}` + count check (`wait_for_all_spans/3`). Cassette s N spans emituje `ceil(N/50)` broadcastů, replay nesmí vrátit po prvním.
4. `Ledger.verify_ledger(new_run_id)` — `hash_valid: true` iff `{:ok, _}` (match? signature-drift-safe per CLAUDE.md).
5. `Comparator.compare(source_run_id, new_run_id)` — diff against source.
6. `Phoenix.PubSub.unsubscribe` v `after` bloku (i při timeout/raise).

**Jak Replayer zachovává hash-chain invariant**:

Žádný bypass. Replay POUŽÍVÁ stejnou cestu jako live ingest:
`SessionGenServer → BufferProducer → Pipeline → Ledger.insert_batch`.
Replay je proto **plnohodnotný nový run** s vlastním validním hash chainem
pod `new_run_id`. `hash_valid: false` v response by znamenalo chain
corrupted — never happens v praxi pro identický replay; je to integrity
canary pro budoucí refactory.

**Důsledek**: cassette payload streams jsou shareable, replay je
reproducible, ale generovaný run_id je vždy unikátní — replay 1000× stejné
cassety = 1000 různých `run_id`-prefixovaných chainů, každý self-konzistentní.

### Web UI vrstvy

- **`/trail`** (`Web.TrailLive`, `trail_live.ex`) — `:index` list runů (50 max),
  `:detail` strom spans z `parent_span_id`. Real-time přes PubSub
  (`"runs"` topic pro index, `"run:#{id}"` pro detail).
- **`/eval/:eval_id`** (`Web.EvalLive`, `eval_live.ex`) — tři views (`:select`,
  `:diff`, `:error`) podle URL query params. **Read-only one-shot, žádný PubSub
  refresh** (na rozdíl od TrailLive). URL je source of truth → view linkable.
- **`/api/*`** (`Web.ApiController`, `controllers/api_controller.ex`, GF-789) — read-only JSON
  API pro React Span Chain UI: `runs` list/detail, per-span `payload` on-demand, `verify`,
  `evals`, `cassettes` list + `replay`. CORS přes Corsica (allowed origins
  `localhost:5173`/`3000`), Bearer auth reuse `AuthPlug`. OOM-safe — list/skeleton jen nativní
  sloupce (žádný `payload`/JSONB), payload jen v `get_span`. **GF-798:** `POST /api/cassettes/:id/replay`
  je **asynchronní** — vrací `202` + `job_id`, replay běží na `Task.Supervisor`
  (`SpanChain.TaskSupervisor`), stav v `replay_jobs` (`ReplayJob`), pollováno přes
  `GET /api/cassettes/replay_jobs/:id`. (Port-4000 `Cassettes.Router` `/cassettes/:id/replay`
  zůstává **synchronní** — 200/408, 15s self-bound; nedotčeno GF-798.)
- **Edge / TLS (GF-769)** — v prod compose stojí před oběma listenery `caddy` (`caddy:2-alpine`,
  kořenový `Caddyfile`) jako jediná HTTPS brána na :443 (automatický TLS — local CA pro
  `DOMAIN=localhost`, Let's Encrypt pro reálnou doménu). Path-routuje `/ingest*` + `/v1/traces*` +
  `/health*` → `app:4000`, vše ostatní → `app:4001` (`handle`, path-preserving — ne prefix-strip).
  App už **nebinduje žádné host porty** (jen interní Docker síť); cert volumes `caddy_data`/`caddy_config`
  přežijí restart. Bare `/evals` + `/cassettes` (port 4000) záměrně neproxovány — UI jede přes `/api` (4001).
- **Span Chain React UI** (`assets/`, GF-792a/801) — frontend tool je React + Vite app, buildí
  se do `priv/static/app.js` + `app.css` + `index.html`. **GF-801:** Vite build entry je
  `assets/index.html` (standardní HTML entry; `src/main.jsx` jen jako `<script type="module">`),
  takže `priv/static/index.html` je teď Vite build output (gitignored, GF-796/801); `emptyOutDir:false`
  zachová `tokens.css` na disku. `tokens.css` je bundlovaný do `app.css` (`main.jsx` import) a
  **odstraněn z `Plug.Static` `only:` whitelistu** (`~w(index.html app.js app.css)`) — žádný
  konzument (`layouts.ex` inline `<style>`), soubor zůstává tracked. `Plug.Static` má
  `cache_control_for_etags` → ETag revalidace/304 (GF-799). Konzumuje `/api/*` (GF-789) přes hooks
  → `apiFetch` (jediné fetch místo, `api/client.js`; per-call `gf_token` validace → brání 431, GF-795);
  `useReplay` je polling state machine pro async replay (GF-803); `SpanTree` má legacy-data banner (GF-797).
  Dev server :5173, proxy `/api`+`/health` → :4001. Detaily: [[Sprints/sprint-13-2026-05-30]], [[Sprints/sprint-14-2026-06-01]].

---

