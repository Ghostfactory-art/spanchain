import { AsyncLocalStorage } from "node:async_hooks";

export interface SpanContext {
  traceId: string;
  spanId: string;
  runId: string;
  evalId?: string;
}

const storage = new AsyncLocalStorage<SpanContext>();

/** Returns current span context, or undefined at root (no enclosing span). */
export function getCurrentContext(): SpanContext | undefined {
  return storage.getStore();
}

/** Runs fn with ctx as the current AsyncLocalStorage store. Per-async-branch isolated. */
export function runWithContext<T>(ctx: SpanContext, fn: () => T): T {
  return storage.run(ctx, fn);
}

// GF-733: a separate ALS for evalId. Reason: SpanContext has required traceId/spanId/runId;
// a top-level evalScope (before the first span) doesn't have them. A separate store = clean single-responsibility
// + preserved type integrity for spanStorage.
const evalStorage = new AsyncLocalStorage<string>();

/** Returns evalId from the nearest enclosing evalScope, or undefined if outside any. */
export function getCurrentEvalId(): string | undefined {
  return evalStorage.getStore();
}

/** Runs fn with evalId as the current eval ALS store. Per-async-task isolated. */
export function runWithEvalId<T>(evalId: string, fn: () => T): T {
  return evalStorage.run(evalId, fn);
}
