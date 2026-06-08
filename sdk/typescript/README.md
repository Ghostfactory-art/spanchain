# @ghostfactory/sdk — TypeScript

OTLP/HTTP JSON exporter + `AsyncLocalStorage` context propagation for
[GhostFactory Observability](../gf_experiment/). Zero runtime dependencies.
Node.js 18+.

## Install

```bash
npm install @ghostfactory/sdk
```

## Quick start

```typescript
import gf from "@ghostfactory/sdk";

gf.init({
  endpoint: "http://localhost:4000",
  apiKey: "dev-secret-change-me",
  runId: "my-agent-run-1",   // optional; UUID v4 if omitted
});

const result = await gf.span("agent_run", { model: "claude-sonnet-4-6" }, async () => {
  return await gf.span("llm_call", { tokens: 512 }, async () => {
    // ... your LLM call ...
    return "response";
  });
});

await gf.flush();   // before process exit; drains the buffered batch
```

Trail UI: `http://localhost:4001/trail/my-agent-run-1`

## Token cost tracking (GF-735)

OTel GenAI semantic convention constants are exported as the `attrs` namespace:

```typescript
import gf, { attrs } from "@ghostfactory/sdk";

await gf.span(
  "llm_call",
  {
    [attrs.GEN_AI_SYSTEM]: "anthropic",
    [attrs.GEN_AI_REQUEST_MODEL]: "claude-sonnet-4-6",
    [attrs.GEN_AI_USAGE_INPUT_TOKENS]: 128,    // → intValue (GF-742)
    [attrs.GEN_AI_USAGE_OUTPUT_TOKENS]: 64,    // → intValue
    [attrs.GF_USAGE_COST_USD]: 0.00096,        // → doubleValue
  },
  async () => llmCall(),
);
```

Each constant is typed as a string literal (`as const`), so
`attrs.GEN_AI_USAGE_INPUT_TOKENS` narrows to `"gen_ai.usage.input_tokens"` —
typos fail at compile time. `gf.usage.cost_usd` uses the `gf.*` namespace
to signal a GhostFactory extension outside the OTel spec; the backend
currently ignores `doubleValue` (L2 acceptable gap).

## Agent config versioning (GF-738)

Record the agent's *configuration* once on the root span. Distinct from
`gen_ai.request.model`, which captures what each individual `llm_call`
invoked — agent config answers "how was the agent set up for this run".

```typescript
const SYSTEM_PROMPT = "You are a helpful assistant specialized in code review.";

await gf.span(
  "agent_run",
  {
    [attrs.GF_AGENT_MODEL]: "claude-sonnet-4-6",
    [attrs.GF_AGENT_SYSTEM_PROMPT_HASH]: attrs.hashPrompt(SYSTEM_PROMPT),
    [attrs.GF_AGENT_TEMPERATURE]: 0.7,
    [attrs.GF_AGENT_VERSION]: "v1.2.0",
  },
  async () => agentLogic(),
);
```

`attrs.hashPrompt(text)` (Node `node:crypto`) produces the same 16-char
SHA-256 fingerprint as the Python `attrs.hash_prompt(text)` — cross-language
parity is verified by the test suite. Empty string is valid. Agent config
attrs appear in EvalLive's structural diff automatically through the
existing `Comparator`.

## Reasoning capture (GF-736)

Capture agent chain-of-thought as a child span under the decision point.
SDK provides only the constants — composition via `gf.span()` stays with
the user ("SDK stays dumb"):

```typescript
import gf, { attrs } from "@ghostfactory/sdk";

await gf.span("agent_decision", {}, async () => {
  // Capture reasoning before acting
  await gf.span(
    "reasoning",
    {
      [attrs.GF_REASONING_THOUGHT]:
        "User asked about pricing. Options: A) direct answer, B) ask for context first.",
      [attrs.GF_REASONING_CONSIDERED]: JSON.stringify([
        "direct answer",
        "ask for context",
      ]),
      [attrs.GF_REASONING_REJECTED]: JSON.stringify(["direct answer"]),
    },
    async () => {}, // reasoning span ends immediately
  );

  // Then act
  await gf.span(
    "llm_call",
    { [attrs.GEN_AI_REQUEST_MODEL]: "claude-sonnet-4-6" },
    async () => llmCall(),
  );
});
```

The `reasoning` span renders in the Trail UI as a child of the decision parent
span, with `startTimeUnixNano`/`endTimeUnixNano` timing captured. Array values
(`considered`, `rejected`) flow as `JSON.stringify(...)` — OTLP has no native
array variant.

## Task delegation metadata (GF-737)

Capture why a parent agent delegated a subtask and who delegated it:

```typescript
import gf, { attrs } from "@ghostfactory/sdk";

await gf.span(
  "subtask",
  {
    [attrs.GF_TASK_REASON]:
      "User query requires DB lookup — delegating to DB agent",
    [attrs.GF_TASK_INPUT]: query.slice(0, 500), // truncate large inputs
    [attrs.GF_TASK_DELEGATED_BY]: "orchestrator-agent-v1",
  },
  async () => dbAgent.run(query),
);
```

`parent_span_id` captures the structural link (who called whom); `gf.task.*`
attrs capture the semantic context (why and with what input). Truncate
`GF_TASK_INPUT` for large inputs — span payload size matters end-to-end.

## Eval support

Associate a run with a GhostFactory Eval. Two paths:

```typescript
// At init time — per-run global, applies to every span until next init
gf.init({ endpoint, apiKey, runId: "run-7", evalId: "eval-llm-v1" });

// Or scoped per async task (GF-733; safe for Promise.all parallelism)
await gf.evalScope("eval-llm-v1", async () => {
  await gf.span("compare", {}, async () => { /* ... */ });
});
```

Both write `gf.eval_id` to the OTLP resource attributes. The backend
late-binds `eval_id` to an already-running SessionGenServer (GF-727), so
the wire-up works regardless of which batch contains the attribute first.

**Parallel-run isolation (GF-733):** `evalScope` is built on `AsyncLocalStorage`
— two concurrent `Promise.all` branches each carrying their own evalId stay
isolated end-to-end. The exporter groups spans by their captured evalId at
flush time and emits one `ResourceSpans` per evalId group, so each run lands
under the correct `gf.eval_id` on the backend even when buffered together.
Parity with Python's `gf.eval_scope` (GF-744). If you need a single evalId for
the whole process, `gf.init({ evalId })` remains the simpler path and acts as a
fallback inside `evalScope`-less spans.

## Attribute types (GF-742)

The SDK dispatches JS types to the right OTLP value variant:

| JS value | OTLP wire shape |
| --- | --- |
| `"text"` | `{stringValue: "text"}` |
| `true` / `false` | `{boolValue: true/false}` |
| `42` (integer) | `{intValue: 42}` |
| `0.003` (non-integer number) | `{doubleValue: 0.003}` |

`typeof value === "boolean"` is checked before `Number.isInteger(value)` —
no risk of `true` becoming `intValue: 1` (JS booleans aren't `number`s, but
the check is pinned by a regression test anyway).

## API

### `init(config)`

```typescript
gf.init({
  endpoint: string,    // GhostFactory backend base URL (port 4000)
  apiKey: string,      // Bearer token sent as Authorization header
  runId?: string,      // optional; UUID v4 generated if omitted
  evalId?: string,     // optional; attached as gf.eval_id resource attr
}): GfConfig
```

Starts a 5-second background flush timer. The timer is `unref()`d so it
won't keep the Node process alive.

### `span(name, attrs, fn)`

```typescript
gf.span<T>(
  name: string,
  attrs: Record<string, string | number | boolean>,
  fn: () => Promise<T>,
): Promise<T>
```

Wraps `fn` in a span. `AsyncLocalStorage` provides parent linkage
automatically — `gf.span` inside another `gf.span` sets `parent_span_id`.
If `gf.init()` hasn't been called, `fn` runs untraced (silent-fail).

If `fn` throws, the span is recorded with `status: "error"` +
`error: <message>` attributes, then the exception is re-thrown.

### `trace(name, attrs?)`

Higher-order wrapper. Useful for instrumenting an existing async function
with a root span:

```typescript
const myAgent = gf.trace("agent_run")(async (prompt: string) => {
  // ... agent logic ...
});

await myAgent("hello");
```

### `evalScope(evalId, fn)` / `flush()` / `shutdown()`

- `evalScope` — runs `fn` (and every `gf.span` nested inside) with `gf.eval_id`
  attached to the span exports. Per-async-task isolated via `AsyncLocalStorage`
  (GF-733); safe for `Promise.all` parallelism, parity with Python's `gf.eval_scope`.
- `flush` — drains the in-memory buffer and exports pending spans
  synchronously. Call before process exit.
- `shutdown` — stops the flush timer and resets internal state. Primarily
  for tests.

## Buffering model

- Spans go to an in-memory buffer on completion.
- Buffer auto-flushes when it reaches 50 spans.
- Background timer flushes every 5 seconds.
- `await gf.flush()` forces a flush before process exit.

This differs from the Python SDK, which posts per-span on context exit.
Both target the OTLP/HTTP JSON endpoint (`/v1/traces`).

## How it differs from the Python SDK

| Concern | Python (`ghostfactory-sdk`) | TypeScript (this) |
|---|---|---|
| Endpoint | `/v1/traces` (OTLP, GF-741) | `/v1/traces` (OTLP) |
| Send model | per-span POST on context exit | buffered (50 / 5 s) + `flush()` |
| Context | `contextvars.ContextVar` | `AsyncLocalStorage` |
| Eval ID | `set_eval_id` + `eval_scope` (per-task isolated) | `evalScope` (per-task isolated via `AsyncLocalStorage`, GF-733) |
| Span ID | `secrets.token_hex(8)` | `crypto.randomBytes(8).toString('hex')` |
| Trace ID | n/a (single span per request) | `crypto.randomBytes(16).toString('hex')` per root |
| Attribute types | int/bool/float dispatch (GF-742) | int/bool/float dispatch (GF-742) |
| Auth | `Authorization: Bearer <key>` | identical |
| Silent-fail | yes | yes |

## Caveats

- **No browser bundle in v0.1**: depends on `node:async_hooks` and
  `node:crypto`. Browser support would need a context shim.
- **No `@opentelemetry/*` interop**: this SDK emits OTLP payloads but
  doesn't share the OTel JS SDK's `Tracer` / `Context` types. Use the
  upstream OTel SDK if you need cross-library context propagation in
  the same process.
- **`doubleValue` ignored by backend**: emitted correctly by the SDK
  (GF-742), but the backend's `OtlpTranslator` extracts only `stringValue`,
  `intValue`, `boolValue` in L2. L3 will add `doubleValue` for numeric
  aggregations.

## Development

```bash
npm install
npm run typecheck   # tsc --noEmit, strict mode
npm run build       # tsc → dist/
npm test            # vitest run (36 tests across 3 files, Sprint 8)
```
