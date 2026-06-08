Date: 2026-05-16
Status: Draft — awaiting Gemini review
Author: Jiří Joneš

Context

The GhostFactory Observability backend runs in Elixir. The customer's agents are in Python (primarily) or TypeScript. We need to define how the SDK communicates with the backend — the exact protocol, data direction, authentication, error handling, and context propagation.

ADR-002-A: Communication protocol

Decision:

L1: HTTP POST JSON to /ingest (custom format)

L2: OTLP/HTTP Protobuf to /v1/traces (OTel standard)

The data direction is one-way: SDK → backend.
The SDK never receives data during normal operation. The backend is a push-only endpoint.

Exception — Audit Replay (L1):
The SDK may call GET /api/runs/:run_id to download the Ledger. This is read-only, a separate endpoint from ingestion.

Reason:

HTTP JSON = zero dependencies in the Python SDK

OTLP L2 = compatibility with LangChain, CrewAI, OpenTelemetry SDK

One-way push = the SDK stays dumb, no state synchronization

ADR-002-B: SDK architecture — the "Dumb Exporter" pattern

Decision: The SDK is a maximally dumb exporter. No business logic, no decision-making.

What the SDK does:

Generates span_id (UUID or random hex)

Records started_at / ended_at

Builds the JSON payload

HTTP POST to /ingest

Buffers locally if the backend is unavailable (max N spans, then drop)

What the SDK does NOT do:

Doesn't know about epochs, the batch strategy, or the hash-chain

Doesn't handle ordering (that's the backend)

Doesn't know about the dead-letter queue

Doesn't do retries (max 1 retry, then drop — the backend has a DLQ)

Reason:

Anything in the Python SDK we have to mirror in the TypeScript SDK

Logic in the backend = one fix fixes all clients

ADR-002-C: Context propagation in async Python

Problem:

async def agent_run(task):
    span_id = harness.start_span("agent_run")  # ← how to pass span_id into nested calls?
    result = await llm.complete(task)           # ← here we want a child span
    harness.end_span(span_id)

Decision: Python contextvars.ContextVar for implicit propagation of run_id and current_span_id.

_run_id: ContextVar[str] = ContextVar('gf_run_id', default=None)
_span_id: ContextVar[str] = ContextVar('gf_span_id', default=None)

@gf.trace(name="agent_run")
async def agent_run(task):
    # run_id and parent_span_id are automatically available via the ContextVar
    async with gf.span("llm_call"):  # parent_span_id is set automatically
        result = await llm.complete(task)
    return result

Benefit: Works across asyncio.create_task, asyncio.gather, and concurrent.futures. The developer does not pass context explicitly.

Limit: Does not work across multiprocessing — to be documented.

ADR-002-D: LLM call tracing and the Decision Trail

Decision: The SDK captures an LLM call and sends it as an event_type: "llm_call" span with decision trail fields in the payload.

Payload schema:

{
  "span_id": "abc123",
  "name": "llm_call",
  "event_type": "llm_call",
  "started_at": "2026-05-16T06:00:00Z",
  "ended_at": "2026-05-16T06:00:01Z",
  "attributes": {
    "model": "claude-sonnet-4-20250514",
    "prompt_tokens": 892,
    "completion_tokens": 156,
    "cost_usd": 0.0023,
    "input": "Analyze this document...",
    "thinking": "The document appears to be...",
    "decision": "I will extract key entities first",
    "output": "Key entities found: ..."
  }
}

thinking field:

Claude API: capture from the extended_thinking response block

OpenAI: null (reasoning models have no public CoT)

Others: null or from a custom system prompt instruction

Implementation:

async def trace_llm_call(client, messages, **kwargs):
    async with gf.span("llm_call") as span:
        response = await client.messages.create(
            messages=messages,
            thinking={"type": "enabled", "budget_tokens": 5000},
            **kwargs
        )
        span.set_attributes({
            "model": kwargs.get("model"),
            "input": messages[-1]["content"][:500],  # truncate
            "thinking": _extract_thinking(response),
            "output": response.content[-1].text[:500]
        })
        return response

ADR-002-E: Authentication

L1: API key in the HTTP header:

X-GF-API-Key: gf_live_abc123

L2: JWT per project (multi-tenant)

SDK configuration:

gf.init(
    endpoint="http://localhost:4000",
    api_key=os.environ["GF_API_KEY"]
)

ADR-002-F: SDK error handling

Decision: The SDK never raises an exception to the customer because of an observability problem.

# SDK failure is silent — the agent continues
try:
    _send_span(span_data)
except Exception as e:
    logger.debug(f"GF SDK: failed to send span: {e}")
    # drop — the backend has a DLQ for Elixir-side failures

Local buffer: If the backend is unavailable, the SDK buffers max 1000 spans in memory. Once the limit is exceeded → drop oldest. The buffer is flushed on the next successful connection.

Open questions for Gemini review

ContextVar vs explicit passing — is ContextVar the right pattern for Python async, or is there a better approach?

Batch vs per-span HTTP — does the SDK send each span separately or in batches? What's the trade-off?

thinking field truncation — is 500 chars enough or too much? How do other SDKs handle it?

SDK buffer persistence — if the agent crashes, the buffer is lost. Does a file-based buffer make sense for L1?

multiprocessing — ContextVar doesn't work across processes. How to handle it for agents in a process pool?