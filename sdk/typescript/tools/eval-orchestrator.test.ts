import { describe, expect, it, vi } from "vitest";

import type { SpanAttrs } from "../src/types.js";
import {
  type GfModule,
  type OrchestratorOpts,
  formatSummary,
  parseCliArgs,
  runOrchestrator,
} from "./eval-orchestrator.js";

function mockGf() {
  const init = vi.fn();
  const evalScopeSpy = vi.fn();
  async function evalScope<T>(id: string, fn: () => Promise<T>): Promise<T> {
    evalScopeSpy(id);
    return fn();
  }
  const flush = vi.fn(async () => undefined);
  async function span<T>(_n: string, _a: SpanAttrs, fn: () => Promise<T>): Promise<T> {
    return fn();
  }
  const module: GfModule = { init, evalScope, span, flush };
  return { module, init, evalScope: evalScopeSpy, flush };
}

function baseOpts(overrides: Partial<OrchestratorOpts> = {}): OrchestratorOpts {
  return {
    evalId: "x",
    runs: 2,
    prompt: "p",
    endpoint: "http://localhost:4000",
    apiKey: "dev-secret-change-me",
    ...overrides,
  };
}

describe("eval-orchestrator", () => {
  it("1. parseCliArgs parses --eval-id, --runs, --prompt", () => {
    const opts = parseCliArgs([
      "--eval-id",
      "my-eval",
      "--runs",
      "5",
      "--prompt",
      "Summarize this",
    ]);
    expect(opts.evalId).toBe("my-eval");
    expect(opts.runs).toBe(5);
    expect(opts.prompt).toBe("Summarize this");
    expect(opts.endpoint).toBe("http://localhost:4000");
    expect(typeof opts.apiKey).toBe("string");
  });

  it("2. run_id format is eval-{evalId}-run-{N} for N = 1..runs", async () => {
    const gf = mockGf();
    const results = await runOrchestrator(baseOpts({ evalId: "demo", runs: 3 }), gf.module);
    expect(results.map((r) => r.runId)).toEqual([
      "eval-demo-run-1",
      "eval-demo-run-2",
      "eval-demo-run-3",
    ]);
  });

  it("3. formatSummary contains View: http://localhost:4001/eval/{evalId} (port 4001, not 4000)", () => {
    const opts = baseOpts({ evalId: "test-123" });
    const summary = formatSummary(opts, [{ runId: "eval-test-123-run-1" }]);
    expect(summary).toContain("View: http://localhost:4001/eval/test-123");
    expect(summary).not.toContain("4000/eval");
  });

  it("4. (GF-733) gf.evalScope() wraps each run, once per run, with the eval_id", async () => {
    const gf = mockGf();
    const opts = baseOpts({ evalId: "spy-eval", runs: 4 });
    await runOrchestrator(opts, gf.module);
    expect(gf.evalScope).toHaveBeenCalledTimes(4);
    for (const call of gf.evalScope.mock.calls) {
      expect(call[0]).toBe("spy-eval");
    }
  });
});
