"""GhostFactory span attribute constants — OTel GenAI Semantic Conventions.

Spec: https://opentelemetry.io/docs/specs/semconv/gen-ai/

Usage:
    from ghostfactory import attrs

    async with gf.span(
        "llm_call",
        **{
            attrs.GEN_AI_SYSTEM: "anthropic",
            attrs.GEN_AI_REQUEST_MODEL: "claude-sonnet-4-6",
            attrs.GEN_AI_USAGE_INPUT_TOKENS: 128,
            attrs.GEN_AI_USAGE_OUTPUT_TOKENS: 64,
        },
    ):
        ...

Token values go as `intValue` thanks to GF-742 type dispatch — the backend stores
them in the `payload` map. The aggregation projection (SUM input_tokens per eval)
is L3 follow-up GF-735.
"""

import hashlib

# Provider / model identity
GEN_AI_SYSTEM = "gen_ai.system"
GEN_AI_REQUEST_MODEL = "gen_ai.request.model"

# Token usage — intValue via GF-742 type dispatch
GEN_AI_USAGE_INPUT_TOKENS = "gen_ai.usage.input_tokens"
GEN_AI_USAGE_OUTPUT_TOKENS = "gen_ai.usage.output_tokens"
GEN_AI_USAGE_TOTAL_TOKENS = "gen_ai.usage.total_tokens"

# Cost — doubleValue (GF extension outside the OTel spec; the backend ignores it in L2,
# emitted for future L3 aggregation). The `gf.*` namespace = a clear non-standard signal.
GF_USAGE_COST_USD = "gf.usage.cost_usd"

# Agent configuration snapshot (GF-738) — record once per run on the root span.
# Captures HOW THE AGENT WAS CONFIGURED (vs gen_ai.request.model, which is
# per-call "what this specific llm_call actually used"). Both have their place.
GF_AGENT_MODEL = "gf.agent.model"
GF_AGENT_SYSTEM_PROMPT_HASH = "gf.agent.system_prompt_hash"
GF_AGENT_TEMPERATURE = "gf.agent.temperature"
GF_AGENT_VERSION = "gf.agent.version"

# Reasoning capture (GF-736) — chain-of-thought per decision point.
# Used as attributes on a child span named "reasoning" under the parent
# agent decision span. Array values (considered, rejected) encode as JSON
# string: json.dumps([...]) — OTLP has no native array variant.
GF_REASONING_THOUGHT = "gf.reasoning.thought"
GF_REASONING_CONSIDERED = "gf.reasoning.considered"
GF_REASONING_REJECTED = "gf.reasoning.rejected"

# Task delegation metadata (GF-737) — provenance for delegated subtasks.
# Used as attributes on the child span representing the delegated task.
# Complements parent_span_id (structural link) with semantic context
# (why delegated, with what input, by whom).
GF_TASK_REASON = "gf.task.reason"
GF_TASK_INPUT = "gf.task.input"  # truncate large inputs (e.g. text[:500]) — span payload size
GF_TASK_DELEGATED_BY = "gf.task.delegated_by"


def hash_prompt(text: str) -> str:
    """SHA-256 fingerprint of a system prompt — first 8 bytes (16 hex chars).

    16 chars is enough: 64 bits = 2^32 collision-resistant for change detection
    (birthday bound), readable in the Trail UI as a fingerprint, and short for the wire.
    Sending the full 64 hex chars makes no sense (we don't store anything as a primary key,
    it's not a hashchain primitive).

    Idempotent: the same prompt → the same hash across processes and machines.
    Safe over the wire: NEVER exposes the prompt content, only its fingerprint.
    An empty string is valid (SHA-256("") deterministically returns a specific hash).
    """
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
