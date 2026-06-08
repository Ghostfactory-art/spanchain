import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";

import gf from "../src/index.js";
import { shutdown } from "../src/client.js";
import { toOtlpKeyValue } from "../src/exporter.js";
import type { OtlpExportRequest, OtlpKeyValue, OtlpResourceSpans, OtlpSpan } from "../src/types.js";

const ENDPOINT = "http://localhost:4000";

// Capture POST bodies from MSW handlers across tests.
const captured: OtlpExportRequest[] = [];

const okHandler = http.post(`${ENDPOINT}/v1/traces`, async ({ request }) => {
  captured.push((await request.json()) as OtlpExportRequest);
  return HttpResponse.json({ partialSuccess: { rejectedSpans: 0 } }, { status: 200 });
});

const server = setupServer(okHandler);

beforeAll(() => server.listen({ onUnhandledRequest: "error" }));
afterAll(() => server.close());

beforeEach(() => {
  captured.length = 0;
  server.resetHandlers(okHandler);
});

afterEach(async () => {
  await shutdown();
});

function findKv(list: OtlpKeyValue[], key: string): OtlpKeyValue | undefined {
  return list.find((kv) => kv.key === key);
}

function firstSpan(req: OtlpExportRequest): OtlpSpan {
  const rs = req.resourceSpans[0] as OtlpResourceSpans;
  const span = rs.scopeSpans[0]?.spans[0];
  if (!span) {
    throw new Error("no span in request");
  }
  return span;
}

function resourceAttrs(req: OtlpExportRequest): OtlpKeyValue[] {
  return (req.resourceSpans[0] as OtlpResourceSpans).resource.attributes;
}

describe("gf SDK", () => {
  it("1. init not called → span() runs fn, returns result, no throw", async () => {
    const result = await gf.span("untraced", { a: "b" }, async () => 42);
    expect(result).toBe(42);
    expect(captured).toHaveLength(0);
  });

  it("2. init called → span() posts to /v1/traces", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-2" });
    await gf.span("llm_call", {}, async () => "done");
    await gf.flush();

    expect(captured).toHaveLength(1);
    const req = captured[0] as OtlpExportRequest;
    expect(firstSpan(req).name).toBe("llm_call");
  });

  it("3. trace() wrapper propagates fn return value", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-3" });
    const wrapped = gf.trace("agent_run")(async (x: number) => x * 2);
    const result = await wrapped(21);
    expect(result).toBe(42);
    await gf.flush();
    expect(firstSpan(captured[0] as OtlpExportRequest).name).toBe("agent_run");
  });

  it("4. SpanAttrs map to OTLP KeyValue list (string/number/boolean/float)", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-4" });
    await gf.span(
      "mixed",
      { model: "claude", tokens: 512, cached: true, cost: 0.003 },
      async () => null,
    );
    await gf.flush();

    const attrs = firstSpan(captured[0] as OtlpExportRequest).attributes;
    expect(findKv(attrs, "model")?.value).toEqual({ stringValue: "claude" });
    expect(findKv(attrs, "tokens")?.value).toEqual({ intValue: 512 });
    expect(findKv(attrs, "cached")?.value).toEqual({ boolValue: true });
    // GF-742: non-integer number → doubleValue (the backend ignores it, L2 acceptable gap)
    expect(findKv(attrs, "cost")?.value).toEqual({ doubleValue: 0.003 });
  });

  it("5. (GF-733) evalScope() adds gf.eval_id to resource attributes", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-5" });
    await gf.evalScope("eval-llm-v1", async () => {
      await gf.span("compare", {}, async () => "ok");
    });
    await gf.flush();

    const evalKv = findKv(resourceAttrs(captured[0] as OtlpExportRequest), "gf.eval_id");
    expect(evalKv?.value).toEqual({ stringValue: "eval-llm-v1" });
  });

  it("6. every request has service.instance.id = config.runId", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-6" });
    await gf.span("a", {}, async () => null);
    await gf.span("b", {}, async () => null);
    await gf.flush();

    for (const req of captured) {
      const kv = findKv(resourceAttrs(req), "service.instance.id");
      expect(kv?.value).toEqual({ stringValue: "run-6" });
    }
  });

  it("7. nested span() — child's parentSpanId equals parent's spanId", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-7" });
    await gf.span("outer", {}, async () => {
      await gf.span("inner", {}, async () => null);
    });
    await gf.flush();

    // Spans across requests; collect all into one list
    const allSpans = captured.flatMap((r) =>
      r.resourceSpans.flatMap((rs) => rs.scopeSpans.flatMap((ss) => ss.spans)),
    );
    const outer = allSpans.find((s) => s.name === "outer");
    const inner = allSpans.find((s) => s.name === "inner");
    expect(outer).toBeDefined();
    expect(inner).toBeDefined();
    expect(outer?.parentSpanId).toBeUndefined();
    expect(inner?.parentSpanId).toBe(outer?.spanId);
    expect(inner?.traceId).toBe(outer?.traceId);
  });

  it("8. AsyncLocalStorage isolation — Promise.all siblings both have parentSpanId=undefined", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-8" });
    await Promise.all([
      gf.span("a", {}, async () => null),
      gf.span("b", {}, async () => null),
    ]);
    await gf.flush();

    const allSpans = captured.flatMap((r) =>
      r.resourceSpans.flatMap((rs) => rs.scopeSpans.flatMap((ss) => ss.spans)),
    );
    const a = allSpans.find((s) => s.name === "a");
    const b = allSpans.find((s) => s.name === "b");
    expect(a?.parentSpanId).toBeUndefined();
    expect(b?.parentSpanId).toBeUndefined();
    expect(a?.traceId).not.toBe(b?.traceId);
  });

  it("9. retry — MSW returns 503 x2 then 200 → fn result propagated, export succeeds", async () => {
    let calls = 0;
    server.use(
      http.post(`${ENDPOINT}/v1/traces`, async ({ request }) => {
        calls += 1;
        if (calls <= 2) {
          return new HttpResponse(null, { status: 503 });
        }
        captured.push((await request.json()) as OtlpExportRequest);
        return HttpResponse.json({ partialSuccess: { rejectedSpans: 0 } }, { status: 200 });
      }),
    );

    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-9" });
    const result = await gf.span("retry_me", {}, async () => "ok");
    await gf.flush();

    expect(result).toBe("ok");
    expect(calls).toBe(3);
    expect(captured).toHaveLength(1);
  });

  it("10. silent-fail — MSW returns 500 x3 → fn returns result, no throw", async () => {
    let calls = 0;
    server.use(
      http.post(`${ENDPOINT}/v1/traces`, () => {
        calls += 1;
        return new HttpResponse(null, { status: 500 });
      }),
    );

    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-10" });
    const result = await gf.span("doomed", {}, async () => "still ok");
    await gf.flush();

    expect(result).toBe("still ok");
    expect(calls).toBe(3);
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GF-734: init() re-init + shutdown() lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  it("11. (GF-734) re-init overwrites runId — a span after re-init has the new service.instance.id", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-A1" });
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-A2" });
    await gf.span("after_reinit", {}, async () => null);
    await gf.flush();

    expect(captured).toHaveLength(1);
    const kv = findKv(resourceAttrs(captured[0] as OtlpExportRequest), "service.instance.id");
    expect(kv?.value).toEqual({ stringValue: "run-A2" });
  });

  it("12. (GF-734) re-init with a non-empty buffer logs a warning and drops", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {
      /* swallow */
    });
    try {
      gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-B1" });
      // The span finishes under run-B1 and lands in the buffer (FLUSH_THRESHOLD=50 → no auto-flush).
      await gf.span("uncommitted", {}, async () => null);
      // Re-init without flush → warning + drop.
      gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-B2" });

      expect(warn).toHaveBeenCalledWith(expect.stringContaining("flush()"));

      // After the drop, flush should send 0 requests — the buffer was cleared on re-init.
      await gf.flush();
      expect(captured).toHaveLength(0);
    } finally {
      warn.mockRestore();
    }
  });

  it("13. (GF-734) shutdown() allows a clean re-init without a warning", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {
      /* swallow */
    });
    try {
      gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-C1" });
      await gf.shutdown(); // drains + clears config

      // After shutdown: config=null → init() logs no warning, even if the buffer
      // contained anything (after the drain it's empty).
      gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-C2" });

      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });

  it("14. (GF-734) a span after re-init has no parentSpanId from the previous run", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-D1" });
    await gf.span("first_run_root", {}, async () => null);
    await gf.flush();
    const firstRunSpanId = firstSpan(captured[0] as OtlpExportRequest).spanId;
    captured.length = 0;

    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-D2" });
    await gf.span("second_run_root", {}, async () => null);
    await gf.flush();

    const secondSpan = firstSpan(captured[0] as OtlpExportRequest);
    expect(secondSpan.parentSpanId).toBeUndefined();
    expect(secondSpan.spanId).not.toBe(firstRunSpanId);
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GF-733: evalScope AsyncLocalStorage — per-task evalId isolation (Python parity)
  // ──────────────────────────────────────────────────────────────────────────

  function evalIdOf(rs: OtlpResourceSpans): string | undefined {
    const kv = findKv(rs.resource.attributes, "gf.eval_id");
    if (kv && "stringValue" in kv.value) {
      return kv.value.stringValue;
    }
    return undefined;
  }

  it("15. (GF-733) evalScope isolates evalId across parallel runs (Promise.all)", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-15" });
    await Promise.all([
      gf.evalScope("eval-A", async () => {
        await new Promise((r) => setTimeout(r, 10)); // yield → enforce race
        await gf.span("task-a", {}, async () => null);
      }),
      gf.evalScope("eval-B", async () => {
        await gf.span("task-b", {}, async () => null);
      }),
    ]);
    await gf.flush();

    const allResourceSpans = captured.flatMap((r) => r.resourceSpans);
    const evalIds = allResourceSpans.map(evalIdOf).filter((v): v is string => v !== undefined);
    expect(evalIds).toContain("eval-A");
    expect(evalIds).toContain("eval-B");

    // Key point: span "task-a" sits under eval-A, "task-b" under eval-B (no cross-contamination).
    const evalAGroup = allResourceSpans.find((rs) => evalIdOf(rs) === "eval-A");
    const evalBGroup = allResourceSpans.find((rs) => evalIdOf(rs) === "eval-B");
    expect(evalAGroup?.scopeSpans.flatMap((ss) => ss.spans).map((s) => s.name)).toEqual([
      "task-a",
    ]);
    expect(evalBGroup?.scopeSpans.flatMap((ss) => ss.spans).map((s) => s.name)).toEqual([
      "task-b",
    ]);
  });

  it("16. (GF-733) evalScope propagates evalId into nested gf.span()", async () => {
    gf.init({ endpoint: ENDPOINT, apiKey: "k", runId: "run-16" });
    await gf.evalScope("eval-nested", async () => {
      await gf.span("outer", {}, async () => {
        await gf.span("inner", {}, async () => null);
      });
    });
    await gf.flush();

    const allResourceSpans = captured.flatMap((r) => r.resourceSpans);
    const evalScopedRs = allResourceSpans.find((rs) => evalIdOf(rs) === "eval-nested");
    expect(evalScopedRs).toBeDefined();
    const names = evalScopedRs!.scopeSpans.flatMap((ss) => ss.spans).map((s) => s.name);
    expect(names.sort()).toEqual(["inner", "outer"]);
  });

  it("17. (GF-733) setEvalId removed from public API (regression)", () => {
    expect((gf as Record<string, unknown>)["setEvalId"]).toBeUndefined();
  });
});

describe("toOtlpKeyValue type dispatch (GF-742)", () => {
  it.each([
    ["string", "hi", { stringValue: "hi" }],
    ["int", 42, { intValue: 42 }],
    ["zero", 0, { intValue: 0 }],
    ["negative int", -7, { intValue: -7 }],
    ["true", true, { boolValue: true }],
    ["false", false, { boolValue: false }],
    ["float", 3.14, { doubleValue: 3.14 }],
    ["small float", 0.003, { doubleValue: 0.003 }],
  ])("dispatches %s to correct OtlpValue variant", (_label, input, expected) => {
    expect(toOtlpKeyValue("k", input as string | number | boolean).value).toEqual(expected);
  });

  it("bool-before-int: true and false never map to intValue", () => {
    // Regression pin: JS `typeof true === "boolean"` protects against this problem
    // unlike Python (where isinstance(True, int)), but we verify explicitly —
    // if someone swaps the check order in toOtlpKeyValue, this test fails.
    expect(toOtlpKeyValue("k", true).value).toEqual({ boolValue: true });
    expect(toOtlpKeyValue("k", false).value).toEqual({ boolValue: false });
    expect(toOtlpKeyValue("k", 1).value).toEqual({ intValue: 1 });
  });
});
