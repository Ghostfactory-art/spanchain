# ghostfactory-sdk — Python

GhostFactory Observability — Python SDK (L1).

Per-async-task observability for AI agents. Sends spans in OTLP/HTTP JSON
format (`POST /v1/traces`, GF-741) to a running gf_experiment backend.

## Install

```bash
pip install -e ".[dev]"        # local dev
# pip install ghostfactory-sdk  # future PyPI
```

Python 3.11+. Single runtime dependency: `httpx`.

## Quick start

```python
import asyncio
import ghostfactory as gf

gf.init(
    endpoint="http://localhost:4000",
    api_key="dev-secret-change-me",
    run_id="my-agent-run-1",  # or None → auto UUID
)

@gf.trace(name="agent_run")
async def run_agent(task: str) -> str:
    async with gf.span("llm_call", model="claude-sonnet-4-6") as s:
        # ... call LLM ...
        s.set("output", "hello world")
    async with gf.span("tool_call", tool_name="search"):
        # ... call tool ...
        pass
    return "done"

asyncio.run(run_agent("review PR #4192"))
```

Trail UI: `http://localhost:4001/trail/my-agent-run-1`

## Token cost tracking (GF-735)

OTel GenAI semantic convention constants live in `ghostfactory.attrs`:

```python
from ghostfactory import attrs

async with gf.span(
    "llm_call",
    **{
        attrs.GEN_AI_SYSTEM: "anthropic",
        attrs.GEN_AI_REQUEST_MODEL: "claude-sonnet-4-6",
        attrs.GEN_AI_USAGE_INPUT_TOKENS: 128,     # → intValue (GF-742)
        attrs.GEN_AI_USAGE_OUTPUT_TOKENS: 64,     # → intValue
        attrs.GF_USAGE_COST_USD: 0.00096,         # → doubleValue
    },
):
    response = await llm_call(...)
```

Token attributes flow through OTLP as `intValue` (GF-742) and land in the
backend Ledger's `payload` map. Aggregate queries (SUM `input_tokens` per
eval) are L3 follow-up. `gf.usage.cost_usd` uses the `gf.*` namespace to
signal a GhostFactory extension outside the OTel spec; the backend currently
ignores `doubleValue` (acceptable L2 gap).

## Agent config versioning (GF-738)

Record the agent's *configuration* (model, system prompt, temperature, code
version) once on the root span. Distinct from `gen_ai.request.model`, which
captures what each individual `llm_call` invoked — agent config answers
"how was the agent set up for this run" and stays stable across the run.

```python
SYSTEM_PROMPT = "You are a helpful assistant specialized in code review."

@gf.trace(name="agent_run")
async def run_agent(task: str):
    async with gf.span(
        "agent_run",
        **{
            attrs.GF_AGENT_MODEL: "claude-sonnet-4-6",
            attrs.GF_AGENT_SYSTEM_PROMPT_HASH: attrs.hash_prompt(SYSTEM_PROMPT),
            attrs.GF_AGENT_TEMPERATURE: 0.7,
            attrs.GF_AGENT_VERSION: "v1.2.0",
        },
    ):
        ...
```

`attrs.hash_prompt(text)` returns a 16-char SHA-256 fingerprint — same prompt
hashes identically across processes and machines, prompt content never crosses
the wire. Empty string is valid. Agent config attrs appear in EvalLive's
structural diff automatically through the existing `Comparator`.

## Reasoning capture (GF-736)

Capture agent chain-of-thought as a child span under the decision point.
SDK provides only the constants — composition from `gf.span()` is up to the user
("SDK stays dumb"):

```python
import json
from ghostfactory import attrs

async with gf.span("agent_decision"):
    # Capture reasoning before acting
    async with gf.span("reasoning", **{
        attrs.GF_REASONING_THOUGHT: "User asked about pricing. Options: A) direct answer, B) ask for context first.",
        attrs.GF_REASONING_CONSIDERED: json.dumps(["direct answer", "ask for context"]),
        attrs.GF_REASONING_REJECTED: json.dumps(["direct answer"]),
    }):
        pass  # reasoning span ends immediately

    # Then act
    async with gf.span("llm_call", **{
        attrs.GEN_AI_REQUEST_MODEL: "claude-sonnet-4-6",
    }):
        result = await llm.complete(prompt)
```

The `reasoning` span renders in the Trail UI as a child of the decision parent
span, with `started_at`/`ended_at` timing captured. Array values (`considered`,
`rejected`) flow as JSON-encoded strings — OTLP has no native array variant.

## Task delegation metadata (GF-737)

Capture why a parent agent delegated a subtask and who delegated it:

```python
from ghostfactory import attrs

async with gf.span("subtask", **{
    attrs.GF_TASK_REASON: "User query requires DB lookup — delegating to DB agent",
    attrs.GF_TASK_INPUT: query[:500],  # truncate large inputs
    attrs.GF_TASK_DELEGATED_BY: "orchestrator-agent-v1",
}):
    result = await db_agent.run(query)
```

`parent_span_id` captures the structural link (who called whom); `gf.task.*`
attrs capture the semantic context (why and with what input). Truncate
`GF_TASK_INPUT` for large inputs — span payload size matters end-to-end.

## Eval support (GF-727 / GF-744)

Associate this run with a GhostFactory Eval so the backend can compare runs:

```python
# Option 1: sticky for the rest of the async context
gf.set_eval_id("eval-llm-v1")

# Option 2: scoped — auto-restore on exit (asyncio.gather-safe)
async with gf.eval_scope("eval-llm-v1"):
    await run_agent("review PR")
```

Both write `gf.eval_id` to the OTLP resource attributes. Per-async-task
isolation via `ContextVar` — two concurrent `eval_scope` blocks in
`asyncio.gather` see their own value without cross-task contamination.

The backend late-binds `eval_id` to an already-running SessionGenServer
(GF-727), so a first batch without `eval_id` followed by a batch with one
still wires up the association.

## Attribute types (GF-742)

The SDK dispatches Python types to the right OTLP value variant:

| Python value | OTLP wire shape |
| --- | --- |
| `"text"` | `{"stringValue": "text"}` |
| `True` / `False` | `{"boolValue": true/false}` |
| `42` (int) | `{"intValue": 42}` |
| `0.003` (float) | `{"doubleValue": 0.003}` |
| `None` / other | `{"stringValue": "None"}` fallback |

`bool` is checked **before** `int` (Python `isinstance(True, int) is True`)
— `True` becomes `boolValue`, never `intValue: 1`.

## Configuration

```python
gf.init(
    endpoint: str,           # GhostFactory backend base URL (port 4000)
    api_key: str,            # Bearer token; sent as Authorization: Bearer <key>
    run_id: str | None,      # optional; UUID v4 generated if omitted
) -> str                     # returns effective run_id
```

Auth header: `Authorization: Bearer <api_key>` — matches
`GfExperiment.Ingestion.AuthPlug`. The SDK **never** raises to the caller —
a failed send logs a warning and parks the span in an in-memory buffer
(`deque(maxlen=1000)`, FIFO eviction is also logged as a warning).

## Reliability — buffered spans + flush (GF-943)

Spans that fail to send (backend outage, network error) are buffered, not
lost. Re-send them with `gf.flush()` — typically at agent shutdown or after
a known outage window:

```python
sent = await gf.flush()   # drains the buffer, re-sends each span
                          # still-failing spans are re-buffered; returns sent count
```

The buffer holds max 1000 spans; past that the oldest span is dropped
(permanent loss) with a warning on the `ghostfactory` logger.

## Architecture

- `_context.py` — `ContextVar` per asyncio task (NEVER `threading.local` —
  would share state across coroutines)
- `_span.py` — `Span` dataclass + `to_dict()` with ISO 8601 "Z" suffix
- `_exporter.py` — `httpx` async POST with 1 retry, silent drop on failure
- `_buffer.py` — in-memory `deque(maxlen=1000)` for spans that failed to send;
  drained by `gf.flush()` (GF-943)
- `attrs.py` — OTel GenAI constants + `gf.*` extensions + `hash_prompt`
  utility (GF-735, GF-738)
- `__init__.py` — public API: `init`, `trace`, `span`, `flush`, `set_eval_id`,
  `eval_scope`, `attrs`

For backend setup, end-to-end smoke tests, and architecture-level details,
see [gf_experiment/docs/development.md](../gf_experiment/docs/development.md)
and [gf_experiment/docs/architecture-map.md](../gf_experiment/docs/architecture-map.md).

## Test

```bash
pytest
# → 60 passed (GF-943)
```
