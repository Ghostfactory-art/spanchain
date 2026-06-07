# Context Index — co číst pro jaký úkol

Rozcestník přes `gf_experiment/docs/`. Cílem je načíst **minimální** sadu souborů pro daný
typ úkolu místo čtení celých velkých dokumentů. Cesty jsou relativní k `docs/`.

| Typ úkolu | Načti tyto soubory |
|---|---|
| Pochopit architekturu / „jak X funguje" | [`architecture-map.md`](architecture-map.md) (§1 přehled + §4 dependency matrix + odkazy) → konkrétní [`arch/*`](arch/) |
| Supervize / OTP / restart strategie | [`arch/supervision-and-otp.md`](arch/supervision-and-otp.md) + [`development.md`](development.md) (Supervision tree — smoke testy) |
| Datový tok end-to-end | [`arch/data-flow.md`](arch/data-flow.md) |
| Ingestion / Broadway / backpressure | [`arch/broadway-pipeline.md`](arch/broadway-pipeline.md) + [`development.md`](development.md) (Broadway Pipeline — dev ops) |
| Hash-chain / ledger / tamper-evidence | [`arch/hash-chain.md`](arch/hash-chain.md) + [`development.md`](development.md) (Verifying the hash chain) |
| Eval / Replay / Cassettes | [`arch/eval-and-replay.md`](arch/eval-and-replay.md) + [`development.md`](development.md) (Eval Framework / Cassettes — HTTP/curl) |
| SDK (Python / TypeScript) | [`arch/sdk-contract.md`](arch/sdk-contract.md) + [`development.md`](development.md) (Python SDK / TypeScript SDK) |
| Test architektura / jak testovat OTP | [`arch/testing-otp.md`](arch/testing-otp.md) + kořenový-projektový `gf_experiment/CLAUDE.md` (Test seams) |
| Setup / spuštění / smoke test | [`development.md`](development.md) (Setup, Smoke test) |
| Open otázky / known limitations | [`arch/open-questions.md`](arch/open-questions.md) |
| Co dělat dál / priority (otevřená práce) | [`BACKLOG.md`](BACKLOG.md) |
| Co se kdy změnilo (recentní, ≥ Sprint 19) | [`CHANGELOG.md`](CHANGELOG.md) |
| Historie / dokončené sprinty | [`archive/BACKLOG-done.md`](archive/BACKLOG-done.md) + [`archive/CHANGELOG-pre-sprint19.md`](archive/CHANGELOG-pre-sprint19.md) |
| Index archivovaných promptů | [`archive/BACKLOG-done.md`](archive/BACKLOG-done.md) (sekce „Prompts archivované") |
| Hranice modulů / dependency matrix | [`architecture-map.md`](architecture-map.md) §4 |
| Architektonická rozhodnutí (ADR) | [`adr/*.md`](adr/) |
| Vizuální diagramy (Mermaid) | [`architecture-diagram.md`](architecture-diagram.md) |
| Payload schémata | [`payload-schemas.md`](payload-schemas.md) |
| Známé problémy / limitace | [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md) |
| Audit / security / code review | [`audit/security-findings.md`](audit/security-findings.md) + [`audit/code-review.md`](audit/code-review.md) |
| Prompt kvalita / eval benchmark | [`audit/prompt-benchmark/report.md`](audit/prompt-benchmark/report.md) (+ [`rubric.md`](audit/prompt-benchmark/rubric.md), [`BACKFILL_RUN.md`](audit/prompt-benchmark/BACKFILL_RUN.md)) |
| Recentní sprint (session review) | [`Sprints/`](Sprints/) (poslední `sprint-NN-YYYY-MM-DD.md`) |

## Struktura docs/

```
docs/
├── CONTEXT_INDEX.md          # tento rozcestník
├── architecture-map.md       # §1 přehled + stub sekce + PLNÁ §4 dependency matrix
├── arch/                     # detailní architektonické sekce (§2/§3/§5–§10)
├── development.md            # dev/ops recepty (setup, curl, IEx, smoke testy)
├── BACKLOG.md                # jen otevřená práce
├── CHANGELOG.md              # recentní okno (≥ Sprint 19 / 2026-06-02)
├── Sprints/                  # živé sprint docs (session review per den)
├── audit/                    # security-findings, code-review, prompt-benchmark/
└── archive/                  # historie (dokončené sprinty, starší changelog, prompty)
```

> Pozn.: `architecture-map.md` §4 (Dependency Matrix) zůstává fyzicky tam — čte ji
> `test/span_chain/docs_test.exs` (GF-743). Detail ostatních sekcí žije v `arch/*`.

## Runbook — archivace/refactoring docs (opakující se)

Až docs zase narostou, postupuj podle **[`CONTEXT_REFACTOR_PLAN.md`](CONTEXT_REFACTOR_PLAN.md)**
— schválený runbook s „Pořadí provedení" (1–6) + Krok 0.5. Klíčový guardrail: `docs_test.exs`
(GF-743) čte JEN `architecture-map.md` a dělá case-sensitive match → arch-map drž jako
§1 + stuby + **plná §4** (ne tenký rozcestník); stuby musí obsahovat markery
`gen_ai`/`gf.agent`/`intValue` + section keywords + soubor > 10 000 B. Root `CLAUDE.md`
edituj jen ZA `<!-- gitnexus:end -->`.

## Workflow — jak načítat kontext

**Stálý kontext (načítá se sám):** obě `CLAUDE.md` (kořenový + `gf_experiment/`) loaduje
harness automaticky — pravidla, invarianty, code layout, test seams, „Do NOT". Neposílej je.

**Začátek úkolu (minimální základ):**
- tento `CONTEXT_INDEX.md` jako mapa (stačí říct „načti kontext podle CONTEXT_INDEX pro issue X")
- `BACKLOG.md` (co je otevřené)
- volitelně `architecture-map.md` (přehled §1 + §4 dependency matrix)

**Per-issue:** z tabulky výše vytáhni 1–2 relevantní soubory (`arch/*` + odpovídající
`development.md` sekci). Příklady: Broadway bug → `arch/broadway-pipeline.md` + development.md
(Broadway ops); hash/ledger → `arch/hash-chain.md` + development.md (Verifying the hash chain).

**Write-back (konec úkolu — nezapomenout):**
- **Nový modul v `lib/span_chain/`** → přidej ho do `architecture-map.md` **§4**, jinak
  `docs_test.exs` (GF-743) spadne.
- **Docs sync:** `CHANGELOG.md` (recentní okno) + nový sprint doc do živé `Sprints/`.
  Starší záznamy časem → `archive/` (viz Runbook výše).
