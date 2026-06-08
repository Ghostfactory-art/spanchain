import { describe, expect, it } from "vitest";

import { attrs } from "../src/index.js";
import { toOtlpKeyValue } from "../src/exporter.js";

describe("attrs constants (GF-735)", () => {
  it("re-exports OTel GenAI semantic convention keys", () => {
    expect(attrs.GEN_AI_SYSTEM).toBe("gen_ai.system");
    expect(attrs.GEN_AI_REQUEST_MODEL).toBe("gen_ai.request.model");
    expect(attrs.GEN_AI_USAGE_INPUT_TOKENS).toBe("gen_ai.usage.input_tokens");
    expect(attrs.GEN_AI_USAGE_OUTPUT_TOKENS).toBe("gen_ai.usage.output_tokens");
    expect(attrs.GEN_AI_USAGE_TOTAL_TOKENS).toBe("gen_ai.usage.total_tokens");
  });

  it("cost uses gf.* namespace (non-OTel extension)", () => {
    expect(attrs.GF_USAGE_COST_USD).toBe("gf.usage.cost_usd");
    expect(attrs.GF_USAGE_COST_USD.startsWith("gf.")).toBe(true);
  });

  it("token int via attrs constant dispatches to intValue (GF-742 + GF-735 integration)", () => {
    // Construct the same KeyValue the exporter would build for a span with
    // { [attrs.GEN_AI_USAGE_INPUT_TOKENS]: 128 } — verify the int reaches OTLP wire.
    const kv = toOtlpKeyValue(attrs.GEN_AI_USAGE_INPUT_TOKENS, 128);
    expect(kv.key).toBe("gen_ai.usage.input_tokens");
    expect(kv.value).toEqual({ intValue: 128 });
  });

  it("cost float via GF_USAGE_COST_USD dispatches to doubleValue", () => {
    const kv = toOtlpKeyValue(attrs.GF_USAGE_COST_USD, 0.00096);
    expect(kv.key).toBe("gf.usage.cost_usd");
    expect(kv.value).toEqual({ doubleValue: 0.00096 });
  });
});

describe("agent config versioning (GF-738)", () => {
  it("GF_AGENT_* constants use gf.agent.* namespace", () => {
    expect(attrs.GF_AGENT_MODEL).toBe("gf.agent.model");
    expect(attrs.GF_AGENT_SYSTEM_PROMPT_HASH).toBe("gf.agent.system_prompt_hash");
    expect(attrs.GF_AGENT_TEMPERATURE).toBe("gf.agent.temperature");
    expect(attrs.GF_AGENT_VERSION).toBe("gf.agent.version");
    for (const k of [
      attrs.GF_AGENT_MODEL,
      attrs.GF_AGENT_SYSTEM_PROMPT_HASH,
      attrs.GF_AGENT_TEMPERATURE,
      attrs.GF_AGENT_VERSION,
    ]) {
      expect(k.startsWith("gf.agent.")).toBe(true);
    }
  });

  it("hashPrompt returns 16-char hex fingerprint", () => {
    const result = attrs.hashPrompt("Hello, world!");
    expect(result).toHaveLength(16);
    expect(result).toMatch(/^[0-9a-f]{16}$/);
  });

  it("hashPrompt is idempotent", () => {
    const p = "You are a helpful assistant.";
    expect(attrs.hashPrompt(p)).toBe(attrs.hashPrompt(p));
  });

  it("hashPrompt produces different hashes for different inputs", () => {
    expect(attrs.hashPrompt("Prompt A")).not.toBe(attrs.hashPrompt("Prompt B"));
  });

  it("hashPrompt matches Python SDK for the empty string (cross-language parity)", () => {
    // SHA-256("") deterministically → e3b0c442... — same hash as Python attrs.hash_prompt("")
    expect(attrs.hashPrompt("")).toBe("e3b0c44298fc1c14");
  });
});

describe("reasoning capture (GF-736)", () => {
  it("GF_REASONING_* constants use gf.reasoning.* namespace", () => {
    expect(attrs.GF_REASONING_THOUGHT).toBe("gf.reasoning.thought");
    expect(attrs.GF_REASONING_CONSIDERED).toBe("gf.reasoning.considered");
    expect(attrs.GF_REASONING_REJECTED).toBe("gf.reasoning.rejected");
    for (const k of [
      attrs.GF_REASONING_THOUGHT,
      attrs.GF_REASONING_CONSIDERED,
      attrs.GF_REASONING_REJECTED,
    ]) {
      expect(k.startsWith("gf.reasoning.")).toBe(true);
    }
  });

  it("matches Python SDK string values (cross-language parity)", () => {
    // Pinned — if Python attrs.py changes the values, its test_attrs.py
    // pytest fails at the same time (identical literal assertions).
    expect(attrs.GF_REASONING_THOUGHT).toBe("gf.reasoning.thought");
    expect(attrs.GF_REASONING_CONSIDERED).toBe("gf.reasoning.considered");
    expect(attrs.GF_REASONING_REJECTED).toBe("gf.reasoning.rejected");
  });
});

describe("task delegation metadata (GF-737)", () => {
  it("GF_TASK_* constants use gf.task.* namespace", () => {
    expect(attrs.GF_TASK_REASON).toBe("gf.task.reason");
    expect(attrs.GF_TASK_INPUT).toBe("gf.task.input");
    expect(attrs.GF_TASK_DELEGATED_BY).toBe("gf.task.delegated_by");
    for (const k of [
      attrs.GF_TASK_REASON,
      attrs.GF_TASK_INPUT,
      attrs.GF_TASK_DELEGATED_BY,
    ]) {
      expect(k.startsWith("gf.task.")).toBe(true);
    }
  });

  it("matches Python SDK string values (cross-language parity)", () => {
    expect(attrs.GF_TASK_REASON).toBe("gf.task.reason");
    expect(attrs.GF_TASK_INPUT).toBe("gf.task.input");
    expect(attrs.GF_TASK_DELEGATED_BY).toBe("gf.task.delegated_by");
  });
});
