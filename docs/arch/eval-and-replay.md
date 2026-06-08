<!-- Source: architecture-map.md §7 — Eval + Replay system -->

## 7. Eval + Replay system

### Eval Framework (GF-706, GF-707)

`Eval` is an umbrella aggregate for comparing multiple `runs` with the same intent.
Use case: "same question, 3 different models → which is best?"

**Data model**:
- `evals` table (`eval.ex`): `eval_id` PK, `name`, `description`, `status`
- `runs.eval_id` FK (`run.ex:26`): nullable, belongs_to Eval with `references: :eval_id`

**How `gf.eval_id` arrives via OTLP**:

In a request to `/v1/traces` the client sends:
```json
{"resourceSpans":[{"resource":{"attributes":[
  {"key":"service.instance.id","value":{"stringValue":"run-fast"}},
  {"key":"gf.eval_id","value":{"stringValue":"eval-llm-v1"}}
]}, ...}]}
```

`OtlpTranslator.extract_eval_id/1` (`otlp_translator.ex:73-80`) extracts it
as a string or `nil`. `Router.handle_otlp/1` (`router.ex:88-91`) passes it into
`SessionSupervisor.ensure_session(run_id, eval_id: eval_id)` — **NOT through the
`ingest_spans/2` signature** (preserves backward compat for `/ingest` JSON,
see CLAUDE.md "Do NOT").

**After GF-751/GF-746 (commit `9c7f03c`)** the passive association is fully moved
into the Broadway pipeline. `SGS.init/1` (`session_gen_server.ex:120-122`) is now
**a no-op DB-wise** — it just builds in-memory state. The per-call `eval_id` (from OTLP
resource attrs or GF-727 late-binding via `ingest_spans/3` opts) lives
in `state.eval_id` and `append_span/2` attaches it to the entry as an in-memory
`:eval_id` sidecar (NOT a Ledger schema field).

**Pipeline.handle_batch/4** (`pipeline.ex:72-130`) then:

```
ensure_run_records(entries)
  → Repo.insert_all("runs", uniq_by(run_id),
      on_conflict: :nothing, conflict_target: [:run_id])

ensure_eval_records(entries)
  → Repo.insert_all("evals", uniq_by(eval_id), ...)            # FK target FIRST
  → from(r in Run, where: r.run_id == ^entry.run_id,
         update: [set: [eval_id: fragment("COALESCE(eval_id, ?)", ?)]])
    |> Repo.update_all([])                                     # COALESCE first-wins

upsert_agent_configs(entries)  # GF-748 gf.agent.*

# strip the :eval_id sidecar BEFORE the Ledger schema insert:
ledger_entries = Enum.map(entries, &Map.delete(&1, :eval_id))
with_retry → Repo.transaction → Ledger.insert_batch(ledger_entries)
broadcast_flushed(entries)
```

**FK ORDER PRESERVED:** the Eval insert in `ensure_eval_records` is FIRST (PK for the
`runs.eval_id` FK), the `Run.eval_id` COALESCE update is SECOND. Any failure
in the metadata phases does NOT CRASH the Pipeline — a defensive `rescue` + `catch` around
each function (per CLAUDE.md "observability must not block data ingestion").

**Semantic shift:** `Run`/`Eval` rows are created only AFTER the first Broadway
flush (batch_timeout 50ms test / 1000ms prod), not at SGS spawn-time.
Invisible to the `/trail` LiveView (read-only post-facto inspection).
Tests asserting synchronous DB visibility after `ingest_spans` must use
`wait_for_all_committed/2` before the DB asserts — see the GF-727 test fixes.

### Comparator (pure tree diff)

`evals/comparator.ex:1-22` › "Pure logic — no GenServer, no state.
Repo.all as the only side effect (deterministic for a given DB snapshot)."

**Algorithm**:
1. `load_run(run_id)` (`comparator.ex:51-66`) — fetch Ledger rows ORDER BY epoch_id, seq + `build_tree`.
2. `build_tree/1` (`comparator.ex:69-79`) — group by `parent_span_id`, attach recursively. Identical algorithm to `TrailLive.build_tree/1` (`trail_live.ex:298-307`); the copied comment in Comparator admits it.
3. `pair_by_name/2` (`comparator.ex:159-183`) — for each name, pair the i-th A with the i-th B (sibling position). `Enum.uniq` on the keys preserves insertion order for a stable `deviation_point`.
4. Generating diff entries:
   - `{:only_a, node}` → `"span_removed"`
   - `{:only_b, node}` → `"span_added"`
   - `{:both, a, b}` → `duration_diff_entry` (>20% threshold in `@duration_threshold` on line 28) + recurse children
5. `mark_deviation_points/1` (`comparator.ex:234-237`) — called per top-level branch inside `diff_trees/2` (`comparator.ex:153` flat_map), marks the first diff entry in the argument list. The per-branch behavior comes from the call site; GF-740 (Sprint 7, commit `aabb26b`) fixed it from the pre-GF-740 global-index-0 behavior.

**Edge cases**:
- Both `eval_id` nil → `:ok` (OK to compare unassigned runs)
- A.eval_id = "x", B.eval_id = "x" → `:ok`
- A.eval_id = "x", B.eval_id = "y" → `{:error, :different_eval}` (`comparator.ex:85-87`)
- Run does not exist → `{:error, :run_not_found}` (`comparator.ex:52-53`)

**Duration computation** (`comparator.ex:209-234`): **payload first**, projection
fallback. The GF-669 projection columns `started_at`/`ended_at` are truncated to
`:second` (`ledger.ex:117`), so sub-second durations give 0. The payload keeps
ISO8601 strings with ms precision. Lesson learned from GF-706.

**Comparator consumers**:
- `Evals.compare/2` defdelegate (`evals.ex:38`) → HTTP `GET /evals/:id/compare`
- `Web.EvalLive` directly (`eval_live.ex:35`) — same OTP app, an HTTP hop would be pointless
- `Cassettes.Replayer` (`replayer.ex:48-52`) — diff replay vs source

### VCR Cassettes (GF-712)

`Cassettes.record/2` (`cassettes.ex:14-43`):
1. Load all `payload` rows for `run_id` ORDER BY epoch_id, seq (`load_payloads/1`).
2. Insert `%Cassette{}` with `snapshot: [payload, payload, ...]` (array of maps).
3. PAYLOAD-FIRST: we store the raw `payload` map, NOT the projection columns. (Lesson from the GF-706 sub-second precision bug.)

`Cassettes.Replayer.replay/2` (`replayer.ex:31-59`) — a **pure module**, not a GenServer:
1. Subscribe to `"run:#{new_run_id}"` **BEFORE** ingest (otherwise you lose the first broadcasts).
2. `SessionSupervisor.ensure_session(new_run_id)` + `SGS.ingest_spans(new_run_id, spans)`.
3. **Multi-batch wait** — receive loop `{:spans_flushed, ^run_id}` + count check (`wait_for_all_spans/3`). A cassette with N spans emits `ceil(N/50)` broadcasts; the replay must not return after the first.
4. `Ledger.verify_ledger(new_run_id)` — `hash_valid: true` iff `{:ok, _}` (match? signature-drift-safe per CLAUDE.md).
5. `Comparator.compare(source_run_id, new_run_id)` — diff against source.
6. `Phoenix.PubSub.unsubscribe` in the `after` block (even on timeout/raise).

**How the Replayer preserves the hash-chain invariant**:

No bypass. Replay USES the same path as live ingest:
`SessionGenServer → BufferProducer → Pipeline → Ledger.insert_batch`.
The replay is therefore a **full new run** with its own valid hash chain
under `new_run_id`. `hash_valid: false` in the response would mean the chain is
corrupted — never happens in practice for an identical replay; it's an integrity
canary for future refactors.

**Consequence**: cassette payload streams are shareable, replay is
reproducible, but the generated run_id is always unique — replaying the same
cassette 1000× = 1000 different `run_id`-prefixed chains, each self-consistent.

### Web UI layers

- **`/trail`** (`Web.TrailLive`, `trail_live.ex`) — `:index` list of runs (50 max),
  `:detail` span tree from `parent_span_id`. Real-time via PubSub
  (`"runs"` topic for index, `"run:#{id}"` for detail).
- **`/eval/:eval_id`** (`Web.EvalLive`, `eval_live.ex`) — three views (`:select`,
  `:diff`, `:error`) per the URL query params. **Read-only one-shot, no PubSub
  refresh** (unlike TrailLive). The URL is the source of truth → the view is linkable.
- **`/api/*`** (`Web.ApiController`, `controllers/api_controller.ex`, GF-789) — read-only JSON
  API for the React Span Chain UI: `runs` list/detail, per-span `payload` on-demand, `verify`,
  `evals`, `cassettes` list + `replay`. CORS via Corsica (allowed origins
  `localhost:5173`/`3000`), Bearer auth reuses `AuthPlug`. OOM-safe — list/skeleton only native
  columns (no `payload`/JSONB), payload only in `get_span`. **GF-798:** `POST /api/cassettes/:id/replay`
  is **asynchronous** — returns `202` + `job_id`, the replay runs on a `Task.Supervisor`
  (`SpanChain.TaskSupervisor`), state in `replay_jobs` (`ReplayJob`), polled via
  `GET /api/cassettes/replay_jobs/:id`. (The port-4000 `Cassettes.Router` `/cassettes/:id/replay`
  stays **synchronous** — 200/408, 15s self-bound; untouched by GF-798.)
- **Edge / TLS (GF-769)** — in the prod compose, `caddy` (`caddy:2-alpine`, the root `Caddyfile`)
  stands in front of both listeners as the single HTTPS gateway on :443 (automatic TLS — local CA for
  `DOMAIN=localhost`, Let's Encrypt for a real domain). It path-routes `/ingest*` + `/v1/traces*` +
  `/health*` → `app:4000`, everything else → `app:4001` (`handle`, path-preserving — not prefix-strip).
  The app no longer **binds any host ports** (only the internal Docker network); the cert volumes `caddy_data`/`caddy_config`
  survive a restart. Bare `/evals` + `/cassettes` (port 4000) are deliberately not proxied — the UI goes through `/api` (4001).
- **Span Chain React UI** (`assets/`, GF-792a/801) — the frontend tool is a React + Vite app, built
  into `priv/static/app.js` + `app.css` + `index.html`. **GF-801:** the Vite build entry is
  `assets/index.html` (standard HTML entry; `src/main.jsx` only as a `<script type="module">`),
  so `priv/static/index.html` is now a Vite build output (gitignored, GF-796/801); `emptyOutDir:false`
  keeps `tokens.css` on disk. `tokens.css` is bundled into `app.css` (`main.jsx` import) and
  **removed from the `Plug.Static` `only:` whitelist** (`~w(index.html app.js app.css)`) — no
  consumer (`layouts.ex` inline `<style>`), the file stays tracked. `Plug.Static` has
  `cache_control_for_etags` → ETag revalidation/304 (GF-799). It consumes `/api/*` (GF-789) via hooks
  → `apiFetch` (the single fetch site, `api/client.js`; per-call `gf_token` validation → prevents 431, GF-795);
  `useReplay` is a polling state machine for async replay (GF-803); `SpanTree` has a legacy-data banner (GF-797).
  Dev server :5173, proxy `/api`+`/health` → :4001. Details: [[Sprints/sprint-13-2026-05-30]], [[Sprints/sprint-14-2026-06-01]].

---

