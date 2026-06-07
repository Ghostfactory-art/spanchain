# Changelog

All notable changes to GhostFactory Observability Core.

Format: `[version] YYYY-MM-DD — description`

---

## [0.46.0] 2026-06-07 — rate limiting :4001 + LP v6 copy + SpanChain rename + secrets hardening

### Added
- **Rate limiting on Phoenix port 4001** (commit `6b9f198`, GF-851): new
  `SpanChain.Web.RateLimiter` (`plug_attack`, no new dependency) on both pipelines — `:api` per
  Bearer token (plug after `AuthPlug`, so unauthorized stays 401), public `/trail` per client IP.
  `429` + `Retry-After` mirroring port 4000. **Separate ETS tables** (`Web.RateLimiter.Api` /
  `.Trail`) keep the buckets independent and decoupled from :4000. Client IP from `x-forwarded-for`
  (Caddy real IP) with `conn.remote_ip` fallback — not raw `remote_ip` (behind the proxy that
  collapses all visitors into one bucket). Closes security audit Finding F1. 3 new tests
  (per-token 429, per-IP via XFF, bucket independence).

### Changed
- **Namespace rename `GfExperiment` → `SpanChain`** (commits `80984bf` + `a6a3c97`, GF-843): app
  atom `:gf_experiment` → `:span_chain`, module namespace, and DB names (`gf_experiment_*` →
  `span_chain_*`). 82 files, 451/451 symmetric (pure rename). Extended to deploy (`Dockerfile`,
  `entrypoint.sh`, `docker-compose.yml`) + `docs/architecture-map.md` so release + `mix test` stay
  green; living docs rebranded per-pattern. **The project folder stays `gf_experiment/`** (not
  renamed) — folder rename + historical-docs rebrand deferred (see BACKLOG). `mix compile` ✅,
  `MIX_ENV=test mix compile` ✅, `mix test` 220/0 ✅, runtime smoke-test green.

### Docs
- **Landing-page copy → Positioning v6** (commit `fa0eb9e`, GF-873): `public/index.html` eyebrow +
  hero lede reframed to "auditable harness for production AI agents" + new Security row in the
  compare table (win cell aligned to v6 vocabulary "Append-only, hash-chained — tamper-evident",
  not "immutable by design"). Driven by Linear Positioning v6.0 FINAL.

### Security
- **`.env.example` hardening** (commit `40ba810`, GF-843/audit): pre-launch secrets sweep (no real
  secrets in git/history; `.env` gitignored + untracked; prod secrets via `System.fetch_env!`
  only). Added a `MIX_ENV=prod` deploy warning (the dev fallback API key is publicly known) and
  de-duplicated `GF_API_KEY`/`SECRET_KEY_BASE` to a single definition each; `config/dev.exs` gained
  an intentional-dev-fallback comment.

---

## [0.45.0] 2026-06-06 — prompt-quality benchmark + PROMPT_TEMPLATE v2 + eval dogfood backfill

### Added
- **Prompt-quality benchmark suite** (commit `4f3984a`): `docs/audit/prompt-benchmark/` —
  `rubric.md`, `scores.jsonl` (re-runnable dataset), `report.md`. 13 L4-WEB/4.6 tickets scored
  across the prompt→plan→impl→outcome chain via a multi-agent workflow (Sonnet scorer + Opus
  adversarial-verify + synth). Mean **21.7/24**; structure perfect (P1/P3/P5/P6 + all of ② = 2.0),
  gap entirely in literal accuracy (P2 **0.69**), Done-When coverage (P4 1.69), redo signal (O1 1.54).
  18/26 claimed defects confirmed after adversarial verify (8 refuted, incl. a false GF-808 "redo").
- **Eval backfill tool** (commits `2ebb407`, `7ab5bad`): `backfill_to_spanchain.py` — worked example
  ingesting the benchmark into Span Chain over OTLP/HTTP. Each ticket = one run (`service.instance.id`)
  under one eval (`gf.eval_id`), modelled as a span tree (root + 3 transitions + 12 dimension leaves);
  score encoded as the comparator-visible `duration` projection (`score × 1000ms`) plus the canonical
  `gf.eval.score` attribute. `--dry-run` (dep-free) + `--only GF-XXX` phased rollout. UTF-8 stdout fix
  for Windows consoles.

### Docs
- **PROMPT_TEMPLATE v2** (commit `8866c11`): rewritten from the benchmark report §6 — 8 ranked,
  evidence-backed changes (author-time path/symbol verification, verbatim PŘED/PO blocks,
  discriminating Done-When greps, call-chain guard in Variant B, new Frontend Variant E,
  gitignore/datetime/migration rules) + a `## ⚠️ Neověřené předpoklady` section, standing
  code-authority line, and a "WHAT NOT TO ADD" list of refuted claims. `/ultrareview` →
  `/code-review ultra`. v1 archived to `prompts/Archive_nepouzito/PROMPT_TEMPLATE.v1-2026-05-16.md`
  (not overwritten). `prompts/README.md` synced (Variant E, Frontend type, anti-patterns 10–12).
- **Backfill run brief** (commit `48b226e`): `docs/audit/prompt-benchmark/BACKFILL_RUN.md` — dogfood
  evidence: 13 runs / 208 spans under eval `prompt-benchmark-2026-06-06`; `compare(GF-808, GF-850)`
  = 4 `duration_diff`s with the deviation point on P2 (verified live). Show HN screenshot placeholder.

### Changed
- `CONTEXT_INDEX.md` now indexes the `docs/audit/*` tree (security-findings, code-review,
  prompt-benchmark) — it was unindexed since the dir was created. `BACKLOG.md` gains a
  Benchmarks/Research row for the re-runnable prompt benchmark.

## [0.44.0] 2026-06-05 — Trail run-list ordering + Connect flow + Docker self-host (GF-855/GF-858)

### Fixed
- **GF-855** (commits `92067dd`, `6ddc0f2`): Trail run-list ordering + "Filed". `list_runs` ordered by
  `started_at DESC`, which is nullable + derived from span data — a null-date run floats to the top
  (Postgres `NULLS FIRST`) and a run with a stale/old `started_at` (e.g. a manual run dated 2024)
  sinks to the bottom, looking "missing" even though the API returns it. Order by `inserted_at`
  (row-creation time: monotonic, always set — verified 0 nulls / 16 runs) and select it; `FileCard` +
  `RegisterRow` "Filed" now read `inserted_at`. No run was ever filtered out (no hidden WHERE). Live
  curl confirms the run is now first; `mix test` 217/0.
- **Connect/auth flow** (commit `15118c2`): the Connect token gate couldn't be submitted (no `<form>`,
  so Enter did nothing) and, worse, the badge hooks (`useRuns`/`useEvals`/`useCassettes`) fetched `/api`
  even with no token — so the Connect screen 401-stormed and `App.onUnauthorized` wiped the just-saved
  `gf_token` on every 401, looking like "token won't save / app 401-locked". Wrapped the inputs in a
  `<form onSubmit>` (Enter works) and gated the hooks on `localStorage.gf_token` (no token → no fetch →
  no wipe), keeping hook calls unconditional (Rules of Hooks safe). eslint clean, `npm test` 51/51.
- **GF-858** (commit `74add46`): containerized stack wouldn't start — Postgres crash-looped on
  "superuser password not specified". The compose file already had `POSTGRES_PASSWORD`/`POSTGRES_DB`
  and `DATABASE_URL` matched; the real cause was that `.env` defines `PGPASSWORD` (native Postgres),
  not `POSTGRES_PASSWORD`, so `${POSTGRES_PASSWORD}` was empty. Added explicit `POSTGRES_USER: postgres`
  (user/db/pw can't drift from `DATABASE_URL`); password supplied via inline env / gitignored
  `.env.docker`, never the protected dev `.env` (GF-783). Stack verified healthy: migrations ran,
  `https://localhost/health` → 200 via Caddy.

### Docs
- `docs/KNOWN-ISSUES.md` errata (commit `d49f427`): dev mode ignores `GF_API_KEY` from `.env` — the
  dev API token is hardcoded to `dev-secret-change-me` (`config/dev.exs:21`); `runtime.exs` only reads
  `GF_API_KEY` in `:prod`. Documents the workaround + that `.env` must never be deleted (GF-783).

## [0.43.0] 2026-06-04 — pre-public hardening: security audit + ingest/API robustness (GF-842/842b/849/850/837)

### Security
- **GF-842** (commit `4917348`): secrets & credentials audit před public repem — 7-bodový checklist
  PASS. `.env` nebyl nikdy commitnut, tracked je jen `.env.example` (placeholdery); žádné hardcoded
  prod secrets v `config/`/`docker-compose.yml`/`mix.exs`/`assets/src/` (vše `System.fetch_env!`/`${VAR}`).
  Fix `gf_experiment/.gitignore`: `.env.local` → `.env.*` glob (+ `!.env.example`) + `config/prod.secret.exs`
  — zavírá mezeru, že `runtime.exs` čte `.env.test`, který dřív nebyl ignorován.
- **GF-842b** (commit `595029f`): deep security review → `docs/audit/security-findings.md` (8 focus
  areas, trace data-flow :4000/:4001 → DB). Verdikt **clean: 0 critical / 0 high**; 1 medium (rate
  limiting chybí na Phoenix :4001 — F1), 2 low (`check_origin: false`; `run_id` nevalidován na :4001
  read API — F3), 4 informational. `mix hex.audit` + `npm audit --audit-level=high` clean. Report-only.
- **GF-850** (commit `d2c664e`): run_id format validace na `/api` (:4001) — zavírá GF-842b F3. Reuse
  public `ValidationPlug.valid_run_id?/1` (single-source regex, GF-774). Read actions přes
  `plug :validate_run_id when action in [:get_run, :get_span, :verify_run]` → 400 `invalid_run_id`;
  `replay_cassette/2` inline guard na user `new_run_id` před `enqueue_replay`. +4 testy, `mix test` 217/0.

### Fixed
- **GF-849** (commit `bd337b6`): OTLP `/v1/traces` bare-match loop → `with/else`. `handle_otlp/1`
  iteroval span groups s bare `{:ok, _} = ensure_session/ingest_spans` — `{:error, reason}` (SGS
  crash/timeout, spawn fail) hodil `MatchError` → HTTP 500 uprostřed iterace → spany ze zbývajících
  groups tiše zahozeny. Nahrazeno `Enum.reduce` s per-group `with/else` (zrcadlí `do_ingest/3`): error
  loguje + pokračuje, status zůstává 200 + `partialSuccess` s **přesným** `rejectedSpans`. +2 testy
  (stub SGS via Registry), `mix test` 213/0.
- **GF-837** (commit `00e5135`): replay banner text per status. `Dossier.jsx` tvrdil „ze zrušeného
  replay jobu" i pro `failed` (= OOM/crash/timeout). Nová pure `replayBannerMessage(status)` v
  `assets/src/hooks/bannerUtils.js` (`failed`→„selhalého") interpolovaná do banneru; podmínka/CSS beze
  změny. +3 vitest (node env), `npm test` 51.

## [0.42.0] 2026-06-04 — failed-banner parity + abort-before-retry + replay_jobs unique index + LP hero (GF-831/830/832/778)

### Added
- **GF-832** (commit `99556a9`): DB-level uniqueness na `replay_jobs.new_run_id`. Sloupec
  je `:string`, `null: false`, fresh per job — neměl ale žádnou DB garanci unikátnosti;
  `get_replay_job_for_run/1` to kompenzoval jen `ORDER BY inserted_at DESC LIMIT 1`. Nová
  migrace `create unique_index(:replay_jobs, [:new_run_id])` (poslední obrana) + changeset
  `unique_constraint(:new_run_id)` → DB violation se vrátí jako čitelné `{:error, changeset}`,
  ne raised `Ecto.ConstraintError`. Tato changeset-error cesta byla dormantní (`replay_cassette/2`
  matchoval jen `{:ok, _}` a `{:error, :not_found}`), takže caller-supplied duplicitní `new_run_id`
  by nově spadl na `CaseClauseError → 500` → přidána klauzule `{:error, %Ecto.Changeset{}}` → 409
  `new_run_id_already_exists`. Additivní, reverzibilní migrace. +2 testy (changeset reject +
  controller 409). `mix ecto.migrate` clean, `mix test` 211/0.
- **GF-831** (commit `18fd5f9`): failed-replay banner parity. `Dossier.jsx` zobrazoval amber
  „neúplný run" banner jen pro `replayJob.status === 'cancelled'`; **failed** replay produkuje
  totožnou past — orphan spany pod `new_run_id` vypadají jako normální kompletní run, ač replay
  crashnul. Podmínka rozšířena na `cancelled || failed`. API už libovolný status vracelo
  (`get_replay_job_for_run/1`), takže pure FE; +1 backend regression test (`/api/runs/:id` vrací
  `replay_job` status `"failed"` bez filtru).

### Fixed
- **GF-830** (commit `18fd5f9`): badge-hook `retry()` vytvářel nový `AbortController` bez zrušení
  předchozího → in-flight fetch z mountu/předchozího retry osiřel (resource leak + možná stale
  setState). Imperativní abort+swap vytažen do pure exportované `nextSignal(abortRef)` v novém
  `assets/src/hooks/abortUtils.js` (abort prior controller PŘED `new AbortController()`, vrací
  signal); `useRuns`/`useEvals`/`useCassettes` `retry()` ji volá, `useEffect` unmount guard (GF-829)
  beze změny. Logika vytažena do utility kvůli testovatelnosti v node-env (hook callback nejde
  renderovat bez RTL). +2 vitest (`nextSignal` happy path + null-ref guard), `npm test` 48.

### Changed
- **GF-778** (commit `35d0541`): LP hero copy swap (`public/index.html`). Nový primární hero
  „You can't ask what your agent did. / You have to *prove it.*" (dvouřádkový, „prove it."
  stamp-red přes inline `var(--stamp-red)` na existujícím `<em>` idiomu — žádné nové CSS, žádný
  vykřičník). Starý tagline „Every agent leaves a record. We keep it." **zachován**, přesunut dolů
  jako `.lede` subheadline. Standalone statická marketing stránka (ne Vite `assets/` entry), žádný
  build krok. Pozn.: hero dosud stamp-red vůbec nepoužíval (akcenty byly gray-`em` / blue-`.ul`).

## [0.41.0] 2026-06-04 — AbortController badge unmount + cancelled-replay banner + Caddy TLS (GF-829/828/769)

### Added
- **GF-828** (commit `a0a2628`): cancelled-replay výstražný banner na run-detail view. Zrušený
  async replay (`cancel_replay_job/1`) může nechat fire-and-forget Task dál ingestovat orphan
  spany do append-only ledgeru pod `new_run_id` — `verify_ledger/1` je správně projde, takže run
  vypadá normálně, ač je neúplný. **Backend:** nový read-only `Cassettes.get_replay_job_for_run/1`
  (přímý match na `replay_jobs.new_run_id` — `:string` sloupec, **ne** UUID, tedy bez `Ecto.UUID.cast`;
  `order_by inserted_at desc` + `limit 1` → `Repo.one` safe; `nil`/non-binary guard → `nil`).
  `ApiController.get_run/2` obohacen o top-level pole `replay_job` (`%{status: "cancelled"} | nil`),
  sibling `run`/`spans`. **Frontend:** `useRun` provleče `run.replay_job` → `runData.replayJob`;
  `Dossier` renderuje amber `run-cancelled-banner` nad span tree když `replayJob.status === 'cancelled'`
  (reuse SpanTree `legacy-banner` inline `var(--amber)` styl, žádné nové CSS/dep). Additivní, bez
  migrace, bez zásahu do hash-chainu. +5 backend testů. `mix test` 208/0 (+1 doctest, +6 properties),
  `npm test` 46/46, `npm run build` OK. (FE banner bez automatického testu — vitest node env, bez
  jsdom/RTL; ověřeno browser krokem.)
- **GF-769** (commit `e08e7fb`): Caddy reverzní proxy + automatický TLS. App dosud bindovala porty
  4000 (Bandit/ingestion) + 4001 (Phoenix/web) přímo na host bez TLS — showstopper pro Bearer tokeny
  a OTLP data přes veřejný internet. Nový kořenový `Caddyfile`: jedna HTTPS brána (`{$DOMAIN:localhost}`,
  local CA pro dev / Let's Encrypt pro prod) path-routuje `/ingest*` + `/v1/traces*` + `/health*` →
  `app:4000`, vše ostatní → `app:4001`. Použit `handle` (path-preserving), nikdy prefix-stripping
  varianta. `docker-compose.yml`: odebrán `app.ports` (app jen v interní Docker síti, žádná host
  expozice), přidána služba `caddy` (`caddy:2-alpine`, 80:80 + 443:443, mount Caddyfile + pojmenované
  `caddy_data`/`caddy_config` volumes pro perzistenci certů, `depends_on app: service_healthy`,
  `DOMAIN` do env aby se proměnná v Caddyfile vyřešila). `.env.example`: `DOMAIN=localhost`. Čistě
  infra — žádný Elixir/config. `docker compose config` exit 0; grepy: žádný prefix-strip, jen `caddy`
  bindује 80/443. Bare `/evals` + `/cassettes` na 4000 záměrně neproxovány (UI jede přes `/api` na 4001).

### Fixed
- **GF-829** (commit `ff29979`): „setState on unmounted component" warning na badge data hookách.
  `useRuns`/`useEvals`/`useCassettes` fetchovaly bez `AbortController` — na 401 → `onUnauthorized` →
  `setView('connect')` → `Bureau` unmount → in-flight fetch doběhl → `.finally(setLoading(false))` na
  unmountnuté komponentě (+ phantom stale-loading při návratu). Každý hook teď vlastní `abortRef`
  (`useRef`), resetuje nový `AbortController` per call uvnitř `retry()` a abortuje ho v `useEffect`
  cleanupu (unmount i retry-change). `signal` je **explicitní DI** parametr workeru → forwardován do
  `apiFetch({onUnauthorized, signal})` → rides `...fetchOptions` do native `fetch` (`client.js` beze
  změny). `.catch` chytá `AbortError` jako první větev (před `UnauthorizedError`, tiše); `.finally`
  guardován `!signal?.aborted`. Workery jsou Promise `.then/.catch/.finally` řetězce (ne async/await),
  takže guardy umístěny do `.catch`/`.finally`; `setError(err.message)` zachován. Žádný `isMounted`
  pattern, žádný App.jsx/backend zásah. +6 vitest (pre-aborted finally guard + AbortError catch path
  ×3 hooky), `npm test` 46/46, `npm run build` OK.

## [0.40.0] 2026-06-04 — Badge retry + apiFetch Context refactor + ghost-task guard (GF-822/808/827)

### Added
- **GF-822** (commit `fca3454`): „Zkusit znovu" retry napříč nav-badge hooky. **Frontend:**
  `useRuns`/`useEvals`/`useCassettes` exportují callable loader (`loadRuns`/`loadEvals`/
  `loadCassettes`) volaný i z `retry()`; error se čistí až na úspěšném refetchi (false-outage chip
  zmizí při skutečném API recovery, ne optimisticky — tím zůstává `disabled`-during-retry smysluplný).
  `App.jsx` liftuje `retry` ze všech tří hooků, odvozuje `hasError`/`retrying`, předává unified
  `onRetry`; `Masthead` má `<Button variant="ghost" sm>` „Zkusit znovu" vedle amber chipu (`disabled`
  během in-flight retry → žádný API spam při přetrvávajícím výpadku). +12 vitest (37/37), `npm run
  build` OK. Bez nových CSS tříd, backend nedotčen.

### Changed
- **GF-808** (commit `4a89a74`): module-level 401 interceptor slot (`_onUnauthorized` +
  `setUnauthorizedHandler`) v `client.js` nahrazen per-render-tree `OnUnauthorizedContext`
  (`src/context/OnUnauthorizedContext.js`, default no-op → žádný null guard) — SSR-safe, žádný
  cross-request leak (L3 prep; chování v současné SPA beze změny). `apiFetch` čte
  `options.onUnauthorized` (destrukturován mimo `fetch` opts), na 401 ho zavolá a pak **stále throwne
  `UnauthorizedError`** (load-bearing pro hook return-pattern guardy + client testy). `App.jsx`
  rozdělen na outer Provider wrapper + inner `Bureau` (App vlastní `view`/handler; Bureau konzumuje
  context přes své hooky pod Providerem — consumer nemůže číst Provider ve vlastním JSX). `onUnauthorized`
  provlečen **všemi 8 apiFetch hooky** (badge workery + `useReplay` ×3 + `useVerify`/`useRun`/
  `useSpanPayload`/`useEval`/`useEvalCompare`) → plná 401→Connect parita, žádná regrese. Client testy
  přepsány na `{onUnauthorized}` option + backward-compat (401 bez option stále throwne, žádný crash).
  40/40 vitest, `npm run build` OK. Backend nedotčen.

### Fixed
- **GF-827** (commit `54e957f`): ghost Task přepisoval `"cancelled"`. `cancel_replay_job/1` flipne
  job na `"cancelled"`, ale fire-and-forget `Task` doběhl a `run_replay_job/1` zapsal `"completed"`/
  `"failed"` bezpodmínečně. Nově je terminal zápis atomický conditional `Repo.update_all` s `WHERE
  status = "running"` (nový private `finish_replay_job/3`, ručně stampuje naive `updated_at`, protože
  `update_all` obchází changeset); jakmile je řádek `"cancelled"` (nebo sweeperem `"failed"`), zápis
  matchne 0 řádků = no-op (invariant: cancelled nikdy nepřepsán; žádný check-then-write race).
  `update_replay_job/2` odstraněn; `run_replay_job/1` `defp`→`def` (public-for-testing, mirror
  `ReplayJobSweeper.sweep_stuck_jobs/0`). Bez migrace, bez `terminate_child` (node-local op nepřežije
  L3 Horde → cooperative PubSub shutdown později). +3 deterministické testy. `mix test` 203/0.
  `cancel_replay_job/1` API i `ReplayJobSweeper` nedotčeny.

## [0.39.0] 2026-06-02 — Replay abort (cancel endpoint + useReplay abort) (GF-823/824)

### Added
- **GF-823** (commit `4089d04`): zrušení běžícího replay jobu napříč vrstvami.
  **Backend:** `Cassettes.cancel_replay_job/1` (UUID-cast guarded; `pending`/`running` →
  `"cancelled"`, terminal → `{:error, :already_terminal}`, unknown/malformed → `{:error, :not_found}`),
  nový `DELETE /api/cassettes/replay_jobs/:id` na `Web.ApiController` (200 `%{status:"cancelled"}` /
  404 / 409), `ReplayJob.changeset/2` dostal `validate_inclusion` se statusem `"cancelled"`, Corsica
  `allow_methods` += `DELETE`. **Frontend:** `useReplay` má `abort()` (clearTimeout + generation-bump
  zastaví polling + best-effort `DELETE` + reset) přes `jobIdRef`, `poll()` bere `"cancelled"` jako
  non-error stop, vrací `abort`; „Zrušit" tlačítko (`<Button>`) v Cassettes během replaye. +6 testů.
  `mix test` 200/0, `npm test` 25/25. Cesta sjednocena na `/api/cassettes/replay_jobs/:id` (stejný
  resource jako polling GET).

### Fixed
- **GF-824** (commit `4089d04`): `useReplay` clearTimeout cleanup na unmount — ověřeno, že už
  existoval (`useEffect` cleanup z GF-803/804); `abort()` přidává další `clearTimeout`. Bez změny
  chování (guard proti tikajícímu timeru po redirectu už byl na místě).

## [0.38.0] 2026-06-02 — useReplay/data-hook auth guards + replay-job sweeper (GF-820/821/807/805)

### Added
- **GF-807 / GF-805** (commit `f9c3c74`): nový `SpanChain.Cassettes.ReplayJobSweeper` — periodic
  GenServer (standalone leaf, Repo-OK), root child za `TaskSupervisor`. `sweep_stuck_jobs/0` označí
  stale `"running"` jobs (`inserted_at` starší než threshold) jako `"failed"` +
  `%{"error" => "timeout_or_killed"}` — chytá `:EXIT` killy (OOM/external/BEAM restart), které
  `run_replay_job/1` `try/rescue` mine (GF-807). `sweep_retention/0` maže completed/failed jobs
  starší než 30 dní (GF-805). Obě veřejné pro test bez mountu; intervaly + threshold přes config
  seamy (test = obří intervaly → sweeper dormant). +5 testů, arch-map §4 řádek. `mix test` 194/0.

### Fixed
- **GF-820** (commit `d1422f8`): `useReplay` guarduje `UnauthorizedError` v `poll()` i `startReplay()`
  (return pattern — apiFetch interceptor už zavolal `_onUnauthorized` → Connect gate). Po GF-804
  (~2.6 min strop) může token expirovat uprostřed replay jobu; bez guardu by 401 spadl do
  `server_error` a uživatel uvízl na Cassettes místo redirectu. Bez nových testů (logická
  ekvivalence). `npm test` 25/25.
- **GF-821** (commit `9647d42`): `useRuns`/`useEvals`/`useCassettes` přešly z GF-818 vzoru
  re-throw + terminal `.catch(() => {})` na **return** pattern (`if (err instanceof UnauthorizedError)
  return`). Slepý absorber polykal výjimky z `.finally()`, `throw` kolidoval s centrálním
  interceptorem (GF-808). Sjednoceno s `useReplay` (GF-820). Bez nových testů. `npm test` 25/25.

## [0.37.0] 2026-06-02 — Badge error state + adaptive replay backoff + Connect button + protected-files guardrails (GF-818/804/809.5/817)

### Added
- **GF-818** (commit `2f7d44c`): nav badge umí třetí stav — `deriveBadgeCount(data, loading, hasError)`
  vrací `'error'` (loading stále vyhrává), Masthead renderuje amber `!` chip (`.ct.badge--error`,
  reuse `--amber` tokenu) místo tichého skrytí badge při API chybě. `App.jsx` liftuje `error`
  z `useRuns`/`useEvals`/`useCassettes` a předává `hasError`; Cassettes drží vlastní ternary
  (`total` je číslo, ne array). Hooky nově **re-thrownou `UnauthorizedError`** (401 zůstává na
  GF-806 Connect gate, ne badge error) + terminální `.catch(() => {})` proti unhandled rejection.
  +4 vitest. Observability nástroj teď signalizuje vlastní výpadek.
- **GF-804** (commit `2b98e5b`): `useReplay` polling přešel z fixních 1500ms na adaptivní backoff —
  pure exportovaná `getInterval(attempt)` (`<5` → 1500, `<15` → 3000, jinak 5000ms). `MAX_ATTEMPTS=40`
  beze změny → strop ~60s → ~2.6 min pro dlouhé agent replaye bez zbytečné chattiness. API kontrakt,
  endpoint i completed/failed logika nedotčeny. +6 vitest threshold testů (nový `useReplay.test.js`).

### Fixed
- **GF-809.5** (commit `9496def`): `Connect.jsx` používal neexistující CSS třídu `btn-sm` (reálná
  pravidla jsou `.btn`/`.btn.sm`) → tlačítka unstyled. Nahrazeno sdílenou `<Button sm>` komponentou
  (Connect → `variant="stamp"`, Disconnect + reveal → `variant="ghost"`) jako každý jiný view.
  Žádná nová CSS třída. **NB:** číslováno `GF-809.5` — GF-809 je už shipnutý jako jiná změna
  (comment cleanup, commit `9463f10`); dohodnuto s uživatelem, aby se nepřepsala historie.

### Docs
- **GF-817** (commit `da69e70`): `CLAUDE.md` „Protected files — NEVER delete or overwrite" sekce
  (`.env`, `priv/static/*`, `*.secret`); předepisuje jiný název pro dočasné Docker/CI env soubory,
  zakazuje glob delete mimo `_build/`/`deps/`/`node_modules/`. Codifikuje poučení z GF-783 incidentu
  (smazaný `.env` → `mix test` `28P01`).

## [0.36.0] 2026-06-02 — Live nav badges + hash cast hygiene + Docker self-hosting (GF-814/816/812/783)

### Added
- **GF-783** (commit `b5fb03b`): docker-compose self-hosting — jeden `docker compose up --build`
  spustí Postgres + app (OTP release). Nové: `lib/span_chain/release.ex` (`migrate/0` přes
  `Ecto.Migrator.with_repo`), multi-stage `Dockerfile` (Debian build+runtime), `docker-compose.yml`
  (`postgres:16-alpine` + app, healthchecky, `depends_on: service_healthy`), `entrypoint.sh`
  (migrate → start), `.dockerignore`, `.gitattributes` (LF pin pro `*.sh`/Dockerfile). `runtime.exs`
  `:prod` blok teď servíruje Phoenix Endpoint (`server: true`, `0.0.0.0:4001`, `check_origin: false`)
  a `DATABASE_SSL` opt-in (default off); `application.ex` bindí Bandit (4000) na `0.0.0.0`; `mix.exs`
  dostal `releases:` blok. **Tři build fixy (deviace od promptu, nutné):** reálný hexpm image tag
  (`1.18.4-erlang-27.3.4.12-…`, promptem uvedený `1.17-erlang-26-…20240610` neexistuje); Node 20 přes
  NodeSource (Debian apt nodejs v18 < Vite 8 min); asset build přes `npm install` (NE `npm ci`/
  `mix assets.deploy` — Windows-resolved `package-lock.json` postrádá Linux-only optional deps →
  `npm ci` EUSAGE). Ověřeno end-to-end: oba kontejnery healthy, `/health` 200, `:4001` HTML, migrace
  proběhly. `mix test` 189/0.
- **GF-814** (commit `d4e47d1`): Cassettes nav badge je live z `/api/cassettes` total (dřív hardcoded
  scaffold `ct: '5'`). `useCassettes` vrací `total` + pure `normalizeCassettes(data)` (zvládá array
  i defensivní object-map shape); `App.jsx` liftuje count do `Masthead`. +1 vitest (pure helper).
- **GF-816** (commit `adaf1b0`): Trail + Evals nav badges live (dřív hardcoded `ct: '42'`/`'3'`).
  Pure `deriveBadgeCount(data, loading)` helper (`loading ? null : data.length`); `App.jsx` liftuje
  county z `useRuns`/`useEvals` (vlastní hook instance per tab — duplicitní GET záměrný dle GF-792a
  no-shared-store); Masthead renderuje per-view badge jen na `typeof === 'number'`. +4 vitest.

### Changed
- **GF-812** (commit `93b170d`): `compute_hash/7` sestavuje hash string s explicitním
  `Integer.to_string/1` pro `seq` a `epoch_id` (místo implicitní `String.Chars` interpolace) — v
  kryptografickém kódu má být každá konverze záměrná a auditovatelná. **Výstup bit-for-bit nezměněn**
  (`Integer.to_string(n) === "#{n}"`), zajištěno novým pinned regression testem proti baseline hexu.
  `mix test` 189/0. Follow-up k GF-787.

## [0.35.0] 2026-06-02 — Auth loop (Connect + globální 401) + hash hardening (GF-802/806/787/809)

### Added
- **GF-802** (commit `a507178`): `Connect.jsx` je funkční token gate (frontend, `assets/`). Zachován
  GF-792a shell (`section.view.active`/`phead`/`connect-grid`); statický credcard nahrazen živým
  inputem (password/reveal toggle, délka 1–256 → `localStorage.setItem('gf_token')` → `onTokenSave()`),
  `.bp` panel zrcadlí stav (SETUP ↔ CONNECTED). `App.jsx`: default view lazy init
  (`gf_token` ? `trail` : `connect`), `handleTokenSave` → `setView('trail')`, `onTokenSave` předán do View.
  Žádný `<form>` (SPA konvence), žádný React Context/Router.
- **GF-806** (commit `1ba73bd`): globální 401 handler přes **API interceptor slot** v `client.js`.
  Nová `UnauthorizedError` + module-level `_onUnauthorized` slot + `setUnauthorizedHandler`; `apiFetch`
  na `res.status === 401` zavolá handler + throwne `UnauthorizedError` (před existující `!res.ok` větví,
  non-401 nedotčeno). `App.jsx` registruje handler jednou v `useEffect` (clear token + `setView('connect')`),
  cleanup na unmount. Architektonické rozhodnutí (Gemini): hooky zůstávají navigation-agnostic, žádný
  `onAuthError` prop-drilling. +3 vitest testy (4→7).

### Changed
- **GF-787** (commit `d87a4e5`): `Ledger.compute_hash/5` → `/7` — `run_id`+`epoch_id` přidány do hash
  vstupu (`seq:prev_hash:event_type:payload:parent_span_id:run_id:epoch_id`). Entry je tak kryptograficky
  vázána ke svému runu/epoše; dřív šlo entry potichu přesunout pod jiný `run_id` v DB bez detekce ve
  `verify_ledger`. `build_entry` + `verify_ledger` předávají oba sloupce; test-only
  `SessionGenServer.compute_hash/4` wrapper smazán, ~11 call sites přepojeno na `Ledger.compute_hash/7`.
  **Rozsah (poctivě):** zavírá naivní SQL relabel; hash zůstává *unkeyed* → útočník s DB write +
  recompute pořád zfalšuje čistý řetěz, truncation ocasu zůstává neviditelná (keyed/HMAC + externí
  anchoring = budoucí práce). **Krok 0 drift:** prompt tvrdil, že `compute_hash` volá jen `ledger.ex`
  — wrapper v SGS existoval. **Pozn.:** dev-DB hard reset (`mix ecto.reset` zde není alias →
  `ecto.drop && ecto.create && ecto.migrate`) je odložen (blokoval běžící server); test DB resetnut čistě.
  `mix test` **188/0** (repurposed wrapper-delegation test na run/epoch binding → count beze změny).

### Chore
- **GF-809** (commit `9463f10`): oprava znění komentáře v `Connect.jsx` (grep-guard fix: `<form` →
  „form element") — uzavírá GF-806 Done-When `grep "<form" assets/src/` = 0 na úrovni HEAD.

---

## Starší záznamy

Verze před Sprint 19 (`[0.34.0]` 2026-06-01 a starší, datum `< 2026-06-02`) byly
archivovány → [`archive/CHANGELOG-pre-sprint19.md`](archive/CHANGELOG-pre-sprint19.md).
