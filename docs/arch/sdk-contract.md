<!-- Source: architecture-map.md §9 — SDK kontrakt -->

## 9. SDK kontrakt

### Python SDK (`ghostfactory-sdk/`)

**Public API** (`__init__.py:23`):
```python
gf.init(endpoint: str, api_key: str, run_id: str | None = None) -> str
gf.trace(name: str, **attrs)                      # decorator pro async funkce
async with gf.span(name: str, **attrs) as s:      # async context manager
    s.set("key", "value")                         # mutate attrs
gf.set_eval_id(eval_id: str | None)               # GF-727 / GF-744 sticky
async with gf.eval_scope(eval_id: str):           # GF-727 / GF-744 scoped (auto-restore)
gf.attrs                                          # GF-735 / GF-738 namespace re-export
```

**Kontext**: `contextvars.ContextVar` (`_context.py`) — `_run_id`,
`_current_span_id`, `_eval_id` (GF-727). Per-task isolated; `asyncio.gather`
a `TaskGroup` vidí každý task svůj eval_id bez kontaminace.
**NIKDY `threading.local`** — sdílel by stav přes coroutines (CLAUDE.md „Do NOT").

**Kam posílá** (post-GF-741): `POST {endpoint}/v1/traces` s OTLP/HTTP JSON
`resourceSpans` envelope (parita s TS SDK). Klíčové mapping:

| Python `Span` | OTLP path |
| --- | --- |
| `span.run_id` | `resource.attributes["service.instance.id"]` — kanonický OTel klíč; `gf.run_id` NEEXISTUJE, backend `OtlpTranslator.extract_run_id/1` ho neumí číst |
| `span.span_id` | `spanId` |
| `span.parent_span_id` | `parentSpanId` (vynecháno pokud `nil`) |
| `span.started_at`/`ended_at` | `startTimeUnixNano`/`endTimeUnixNano` (string ns) |
| `span.attributes` + `status`/`error` merged | `attributes` — GF-742 type dispatch: `intValue` / `boolValue` / `doubleValue` / `stringValue` fallback (bool checked PŘED int — `isinstance(True, int) is True`) |
| `eval_id` (optional) | `resource.attributes["gf.eval_id"]` — explicit param > ContextVar > None resolution v `_build_otlp_payload` (GF-727) |

**Send model**: per-span on context exit (`__init__.py` `span/2` finally
block). Žádný buffering v normální cestě — `await send_span(...)` ihned po
`__aexit__`. Pokud send fails → `buffer_push(s)` (in-memory deque, max 1000).
Send-path failures jsou silent debug log; SDK **NIKDY neraisuje** k volajícímu.

**`attrs` module** (GF-735, GF-738, GF-736, GF-737): `gen_ai.*` OTel GenAI
semantic convention konstanty (input_tokens, output_tokens, request.model,
system) + `gf.agent.*` GF extension (model, system_prompt_hash, temperature,
version) + `gf.reasoning.*` GF extension (thought, considered, rejected —
reasoning capture pattern jako child span pod decision pointem) +
`gf.task.*` GF extension (reason, input, delegated_by — task delegation
provenance pro multi-agent systémy; doplňuje `parent_span_id` strukturální
link sémantickým kontextem) + `hash_prompt` utility (SHA-256[:16]).
`hash_prompt(text) == hashPrompt(text)` cross-language parita testovaná;
`gf.reasoning.*` a `gf.task.*` string-value parita taky pinned.

### TypeScript SDK (`ghostfactory-ts-sdk/`)

**Public API** (`src/index.ts`):
```typescript
gf.init({endpoint, apiKey, runId, evalId?})
gf.span(name, attrs, async () => {...})           // higher-order, returns fn result
gf.trace(name)(fn)                                // higher-order decorator
gf.setEvalId(id)                                  // ⚠ module-level (GF-733 to fix)
await gf.flush()                                  // explicit drain before exit
gf.shutdown()
import { attrs } from "@ghostfactory/sdk"         // GF-735 / GF-738 constants
```

**Kontext**: `AsyncLocalStorage` z `node:async_hooks` — Node ekvivalent
ContextVar. Per-task isolated PRO span hierarchy; `setEvalId` ale píše do
module-level config (GF-733 tracked — parallel `Promise.all` runs vidí
last-writer-wins pro eval_id).

**Kam posílá**: `POST {endpoint}/v1/traces` s **OTLP/HTTP JSON** payload
(`resourceSpans` shape per OTel spec). TS SDK je „standard-OTel front door" —
testovací bridge mezi GhostFactory a běžnými OTel exportery.

**Send model**: buffered (50 spans / 5 s) + `flush()`. Důvod pro buffering:
Node nemá per-coroutine cleanup hook jako Python `__aexit__`; spans končí
explicitně, ale flush se odkládá kvůli network efficiency.

**Attribute dispatch** (`exporter.ts` `toOtlpKeyValue/2`, GF-742): `typeof
value === "string"` → `stringValue`; `typeof === "boolean"` → `boolValue`
(checked PŘED number — pro JS žádné isinstance(True, int) risk, ale pinned
regression test stejně); `Number.isInteger(value)` → `intValue`; jinak
`doubleValue`. `OtlpValue` discriminated union v `types.ts` rozšířena o
`doubleValue` variantu.

**`attrs` namespace** (GF-735, GF-738): stejné konstanty jako Python (literal
string types přes `as const` — typo v konstantě = compile error) +
`hashPrompt(text)` (Node `node:crypto`). Cross-language parita pinned by
`hashPrompt("") === "e3b0c44298fc1c14"` test.

### „SDK stays dumb" — co řeší backend

ADR-001 princip. SDK NEMÁ:
- Žádnou hash computation (backend přes `Ledger.compute_hash/7`).
- Žádnou retry logiku (backend přes `Pipeline.with_retry/3`).
- Žádný eval comparison (backend přes `Evals.Comparator`).
- Žádný canonical encoding (backend přes `PayloadSerializer.canonical_encode`).

SDK rozhodne POUZE:
1. Vygenerování `span_id` (per-span random hex, 8 bytes).
2. Capture `started_at` / `ended_at` (clock SDK procesu).
3. Capture parent z context (ContextVar / AsyncLocalStorage).
4. Serializace na HTTP body.
5. Send + retry-on-fail (best-effort, silent).

Důvod: pokud bychom přidali další SDK (Go, Rust, ...), backend zůstane
single source of integrity. SDK lze udržovat naivně — vše co může selhat
silně se silně testuje backend-side.

---

