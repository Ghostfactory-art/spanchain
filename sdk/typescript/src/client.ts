import { runWithEvalId } from "./context.js";
import { exportSpans } from "./exporter.js";
import { newRunId } from "./ids.js";
import type { BufferedSpan, GfConfig, OtlpSpan } from "./types.js";

const FLUSH_THRESHOLD = 50;
const FLUSH_INTERVAL_MS = 5_000;

let config: GfConfig | null = null;
let buffer: BufferedSpan[] = [];
let flushTimer: NodeJS.Timeout | null = null;
let inFlightFlush: Promise<void> | null = null;

/** Initialize the SDK. Generates a UUID runId if not provided. Starts a 5s flush interval.
 *
 * GF-734: re-init is allowed (the eval orchestrator calls init() per run). If the
 * buffer is not empty at re-init, spans from the previous run would otherwise be
 * silently exported with the NEW `service.instance.id` resource attr — cross-run
 * contamination. We defensively drop the buffer + warn so the caller knows they should
 * have called `flush()` (or `shutdown()`) before re-init.
 */
export function init(opts: GfConfig): GfConfig {
  if (config && buffer.length > 0) {
    // eslint-disable-next-line no-console
    console.warn(
      `[GF] init() called with ${buffer.length} spans in buffer — ` +
        "call flush() before re-init to avoid data loss. Dropping.",
    );
  }
  config = { ...opts, runId: opts.runId ?? newRunId() };
  buffer = []; // GF-734: a clean buffer for the new run, no carry-over
  if (flushTimer === null) {
    flushTimer = setInterval(() => {
      void flush();
    }, FLUSH_INTERVAL_MS);
    // Don't keep the Node process alive just for the timer.
    flushTimer.unref?.();
  }
  return config;
}

/** Current config, or null if init() hasn't been called. */
export function getConfig(): GfConfig | null {
  return config;
}

/** GF-733: per-task isolated evalId via AsyncLocalStorage. Spans inside `fn` (and any
 * nested `gf.span()` calls) carry `evalId` as their `gf.eval_id` resource attribute;
 * exporter groups them in distinct ResourceSpans at flush time. Safe for concurrent
 * `Promise.all([evalScope("A", ...), evalScope("B", ...)])` — each branch sees its own
 * value without cross-task contamination (parity with Python `gf.eval_scope`). */
export async function evalScope<T>(evalId: string, fn: () => Promise<T>): Promise<T> {
  return runWithEvalId(evalId, fn);
}

/** Enqueue a span; if the buffer reaches threshold, schedule an async flush. */
export function push(span: OtlpSpan, evalId?: string): void {
  buffer.push({ otlp: span, ...(evalId ? { evalId } : {}) });
  if (buffer.length >= FLUSH_THRESHOLD) {
    void flush();
  }
}

/** Drain the buffer and export. Waits for any in-flight flush first. No-op if no config. */
export async function flush(): Promise<void> {
  if (inFlightFlush) {
    await inFlightFlush;
  }
  if (!config || buffer.length === 0) {
    return;
  }
  const toSend = buffer;
  buffer = [];
  const cfg = config;
  inFlightFlush = exportSpans(toSend, cfg).then(() => undefined);
  try {
    await inFlightFlush;
  } finally {
    inFlightFlush = null;
  }
}

/** Drain remaining spans, stop the flush interval, reset internal state.
 *
 * GF-734: async, awaits `flush()` before the clear. Lifecycle hook for:
 *   - test teardown (`afterEach(async () => await shutdown())`)
 *   - clean process exit (`await gf.shutdown()` before `process.exit`)
 *
 * After `shutdown()`, `config = null` → the next `init()` logs no warning
 * (a clean re-init without the carry-over warning).
 */
export async function shutdown(): Promise<void> {
  await flush();
  if (flushTimer !== null) {
    clearInterval(flushTimer);
    flushTimer = null;
  }
  config = null;
  buffer = [];
  inFlightFlush = null;
}
