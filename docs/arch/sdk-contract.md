<!-- Source: architecture-map.md §9 — SDK contract -->

## 9. SDK contract

### Python SDK (`ghostfactory-sdk/`)

**Public API** (`__init__.py:23`):
```python
gf.init(endpoint: str, api_key: str, run_id: str | None = None) -> str
gf.trace(name: str, **attrs)                      # decorator for async functions
async with gf.span(name: str, **attrs) as s:      # async context manager
    s.set("key", "value")                         # mutate attrs
gf.set_eval_id(eval_id: str | None)               # GF-727 / GF-744 sticky
async with gf.eval_scope(eval_id: str):           # GF-727 / GF-744 scoped (auto-restore)
gf.attrs                                          # GF-735 / GF-738 namespace re-export
```

**Context**: `contextvars.ContextVar` (`_context.py`) — `_run_id`,
`_current_span_id`, `_eval_id` (GF-727). Per-task isolated; `asyncio.gather`
and `TaskGroup` each see their own task's eval_id without contamination.
**NEVER `threading.local`** — it would share state across coroutines (CLAUDE.md "Do NOT").

**Where it sends** (post-GF-741): `POST {endpoint}/v1/traces` with an OTLP/HTTP JSON
`resourceSpans` envelope (parity with the TS SDK). Key mapping:

| Python `Span` | OTLP path |
| --- | --- |
| `span.run_id` | `resource.attributes["service.instance.id"]` — the canonical OTel key; `gf.run_id` DOES NOT EXIST, the backend `OtlpTranslator.extract_run_id/1` can't read it |
| `span.span_id` | `spanId` |
| `span.parent_span_id` | `parentSpanId` (omitted if `nil`) |
| `span.started_at`/`ended_at` | `startTimeUnixNano`/`endTimeUnixNano` (string ns) |
| `span.attributes` + `status`/`error` merged | `attributes` — GF-742 type dispatch: `intValue` / `boolValue` / `doubleValue` / `stringValue` fallback (bool checked BEFORE int — `isinstance(True, int) is True`) |
| `eval_id` (optional) | `resource.attributes["gf.eval_id"]` — explicit param > ContextVar > None resolution in `_build_otlp_payload` (GF-727) |

**Send model**: per-span on context exit (`__init__.py` `span/2` finally
block). No buffering on the normal path — `await send_span(...)` immediately after
`__aexit__`. If a send fails → `buffer_push(s)` (in-memory deque, max 1000).
Send-path failures are a silent debug log; the SDK **NEVER raises** to the caller.

**`attrs` module** (GF-735, GF-738, GF-736, GF-737): `gen_ai.*` OTel GenAI
semantic convention constants (input_tokens, output_tokens, request.model,
system) + `gf.agent.*` GF extension (model, system_prompt_hash, temperature,
version) + `gf.reasoning.*` GF extension (thought, considered, rejected —
reasoning capture pattern as a child span under a decision point) +
`gf.task.*` GF extension (reason, input, delegated_by — task delegation
provenance for multi-agent systems; complements the `parent_span_id` structural
link with semantic context) + the `hash_prompt` utility (SHA-256[:16]).
`hash_prompt(text) == hashPrompt(text)` cross-language parity is tested;
`gf.reasoning.*` and `gf.task.*` string-value parity is also pinned.

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

**Context**: `AsyncLocalStorage` from `node:async_hooks` — the Node equivalent of
ContextVar. Per-task isolated FOR the span hierarchy; `setEvalId`, however, writes to
module-level config (GF-733 tracked — parallel `Promise.all` runs see
last-writer-wins for eval_id).

**Where it sends**: `POST {endpoint}/v1/traces` with an **OTLP/HTTP JSON** payload
(`resourceSpans` shape per the OTel spec). The TS SDK is a "standard-OTel front door" —
a test bridge between GhostFactory and ordinary OTel exporters.

**Send model**: buffered (50 spans / 5 s) + `flush()`. The reason for buffering:
Node has no per-coroutine cleanup hook like Python's `__aexit__`; spans end
explicitly, but the flush is deferred for network efficiency.

**Attribute dispatch** (`exporter.ts` `toOtlpKeyValue/2`, GF-742): `typeof
value === "string"` → `stringValue`; `typeof === "boolean"` → `boolValue`
(checked BEFORE number — for JS there's no isinstance(True, int) risk, but a pinned
regression test exists anyway); `Number.isInteger(value)` → `intValue`; otherwise
`doubleValue`. The `OtlpValue` discriminated union in `types.ts` is extended with the
`doubleValue` variant.

**`attrs` namespace** (GF-735, GF-738): the same constants as Python (literal
string types via `as const` — a typo in a constant = compile error) +
`hashPrompt(text)` (Node `node:crypto`). Cross-language parity pinned by the
`hashPrompt("") === "e3b0c44298fc1c14"` test.

### "SDK stays dumb" — what the backend handles

The ADR-001 principle. The SDK has NONE of:
- No hash computation (backend via `Ledger.compute_hash/7`).
- No retry logic (backend via `Pipeline.with_retry/3`).
- No eval comparison (backend via `Evals.Comparator`).
- No canonical encoding (backend via `PayloadSerializer.canonical_encode`).

The SDK decides ONLY:
1. Generating `span_id` (per-span random hex, 8 bytes).
2. Capturing `started_at` / `ended_at` (the SDK process's clock).
3. Capturing the parent from context (ContextVar / AsyncLocalStorage).
4. Serialization to the HTTP body.
5. Send + retry-on-fail (best-effort, silent).

Reason: if we add another SDK (Go, Rust, ...), the backend stays the
single source of integrity. The SDK can be kept naive — everything that can fail
hard is tested hard backend-side.

---

