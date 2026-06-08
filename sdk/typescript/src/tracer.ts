import { getConfig, push } from "./client.js";
import {
  getCurrentContext,
  getCurrentEvalId,
  runWithContext,
  type SpanContext,
} from "./context.js";
import { attrsToKeyValueList } from "./exporter.js";
import { newSpanId, newTraceId } from "./ids.js";
import { nowNanoString } from "./time.js";
import type { OtlpKeyValue, OtlpSpan, SpanAttrs } from "./types.js";

/** Run fn inside a new span. If gf isn't initialized, fn runs untraced (silent-fail). */
export async function span<T>(name: string, attrs: SpanAttrs, fn: () => Promise<T>): Promise<T> {
  const config = getConfig();
  if (!config || !config.runId) {
    return fn();
  }

  const parent = getCurrentContext();
  const spanId = newSpanId();
  const traceId = parent?.traceId ?? newTraceId();
  // GF-733 priority: parent span (already inherits evalScope) → evalScope ALS → init's evalId.
  const evalId = parent?.evalId ?? getCurrentEvalId() ?? config.evalId;

  const ctx: SpanContext = {
    traceId,
    spanId,
    runId: config.runId,
    ...(evalId ? { evalId } : {}),
  };

  const startTimeUnixNano = nowNanoString();
  let endTimeUnixNano = startTimeUnixNano;
  const extraAttrs: OtlpKeyValue[] = [];
  let thrown: unknown;

  try {
    return await runWithContext(ctx, fn);
  } catch (err) {
    thrown = err;
    extraAttrs.push({ key: "status", value: { stringValue: "error" } });
    extraAttrs.push({
      key: "error",
      value: { stringValue: err instanceof Error ? err.message : String(err) },
    });
    throw err;
  } finally {
    endTimeUnixNano = nowNanoString();
    const otlp: OtlpSpan = {
      traceId,
      spanId,
      ...(parent ? { parentSpanId: parent.spanId } : {}),
      name,
      startTimeUnixNano,
      endTimeUnixNano,
      attributes: [...attrsToKeyValueList(attrs), ...extraAttrs],
    };
    // GF-733: pass evalId from the current span ctx into the buffer for exporter grouping
    push(otlp, ctx.evalId);
    // touching thrown silences noUnusedLocals when no catch ran
    void thrown;
  }
}

/** Higher-order wrapper: gf.trace('agent_run')(async fn). Wraps fn in a span with given name. */
export function trace(name: string, attrs: SpanAttrs = {}) {
  return function wrap<TArgs extends unknown[], TReturn>(
    fn: (...args: TArgs) => Promise<TReturn>,
  ): (...args: TArgs) => Promise<TReturn> {
    return (...args: TArgs) => span(name, attrs, () => fn(...args));
  };
}
