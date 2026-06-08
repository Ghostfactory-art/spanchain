/**
 * GhostFactory span attribute constants — OTel GenAI Semantic Conventions.
 * Spec: https://opentelemetry.io/docs/specs/semconv/gen-ai/
 *
 * Token values flow through OTLP as `intValue` (GF-742 type dispatch); backend
 * stores them in the `payload` map. Aggregate projections (SUM input_tokens
 * per eval) are L3 follow-up to GF-735.
 */

import { createHash } from "node:crypto";

// Provider / model identity
export const GEN_AI_SYSTEM = "gen_ai.system" as const;
export const GEN_AI_REQUEST_MODEL = "gen_ai.request.model" as const;

// Token usage — intValue via GF-742 type dispatch
export const GEN_AI_USAGE_INPUT_TOKENS = "gen_ai.usage.input_tokens" as const;
export const GEN_AI_USAGE_OUTPUT_TOKENS = "gen_ai.usage.output_tokens" as const;
export const GEN_AI_USAGE_TOTAL_TOKENS = "gen_ai.usage.total_tokens" as const;

// Cost — doubleValue (GF extension outside OTel spec; backend ignores in L2,
// emitted for future L3 aggregations). `gf.*` namespace = clear non-standard signal.
export const GF_USAGE_COST_USD = "gf.usage.cost_usd" as const;

// Agent configuration snapshot (GF-738) — record once per run on the root span.
// Captures HOW the agent was CONFIGURED (vs gen_ai.request.model which is per-call
// "what this specific llm_call used"). Both have their place.
export const GF_AGENT_MODEL = "gf.agent.model" as const;
export const GF_AGENT_SYSTEM_PROMPT_HASH = "gf.agent.system_prompt_hash" as const;
export const GF_AGENT_TEMPERATURE = "gf.agent.temperature" as const;
export const GF_AGENT_VERSION = "gf.agent.version" as const;

// Reasoning capture (GF-736) — chain-of-thought per decision point.
// Used as attributes on a child span named "reasoning" under the parent
// agent decision span. Array values (considered, rejected) encode as JSON
// string: JSON.stringify([...]) — OTLP has no native array variant.
export const GF_REASONING_THOUGHT = "gf.reasoning.thought" as const;
export const GF_REASONING_CONSIDERED = "gf.reasoning.considered" as const;
export const GF_REASONING_REJECTED = "gf.reasoning.rejected" as const;

// Task delegation metadata (GF-737) — provenance for delegated subtasks.
// Used as attributes on the child span representing the delegated task.
// Complements parent_span_id (structural link) with semantic context
// (why delegated, with what input, by whom).
export const GF_TASK_REASON = "gf.task.reason" as const;
// Truncate large inputs (e.g. text.slice(0, 500)) — span payload size matters.
export const GF_TASK_INPUT = "gf.task.input" as const;
export const GF_TASK_DELEGATED_BY = "gf.task.delegated_by" as const;

/**
 * SHA-256 fingerprint of a system prompt — first 8 bytes (16 hex chars).
 *
 * 16 chars is enough: 64 bits = 2^32 collision-resistant for change detection
 * (birthday bound), readable in the Trail UI as a fingerprint, short on the wire.
 *
 * Idempotent: same prompt → same hash across processes and machines.
 * Safe over wire: NEVER exposes prompt content, only its fingerprint.
 * Empty string is valid (SHA-256("") yields a deterministic hash).
 */
export function hashPrompt(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex").slice(0, 16);
}
