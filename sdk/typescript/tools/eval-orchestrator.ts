import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

import gf from "../src/index.js";
import type { SpanAttrs } from "../src/types.js";

export interface OrchestratorOpts {
  evalId: string;
  runs: number;
  prompt: string;
  endpoint: string;
  apiKey: string;
}

export interface RunResult {
  runId: string;
}

/** Minimal subset of the SDK surface the orchestrator depends on — dependency-injection seam for tests. */
export interface GfModule {
  init(opts: { endpoint: string; apiKey: string; runId: string }): unknown;
  evalScope<T>(evalId: string, fn: () => Promise<T>): Promise<T>;
  span<T>(name: string, attrs: SpanAttrs, fn: () => Promise<T>): Promise<T>;
  flush(): Promise<void>;
  shutdown?(): Promise<void> | void;
}

const DEFAULT_ENDPOINT = "http://localhost:4000";
const VIEWER_BASE = "http://localhost:4001/eval";

/** Parse CLI args using node:util parseArgs. `--runs` is coerced to int. */
export function parseCliArgs(argv: string[]): OrchestratorOpts {
  const { values } = parseArgs({
    args: argv,
    options: {
      "eval-id": { type: "string" },
      runs: { type: "string", default: "3" },
      prompt: { type: "string" },
      endpoint: { type: "string", default: DEFAULT_ENDPOINT },
      "api-key": { type: "string" },
    },
    strict: true,
    allowPositionals: false,
  });

  const evalId = values["eval-id"];
  if (typeof evalId !== "string" || evalId === "") {
    throw new Error("--eval-id is required");
  }
  const prompt = values.prompt;
  if (typeof prompt !== "string" || prompt === "") {
    throw new Error("--prompt is required");
  }

  const runsStr = typeof values.runs === "string" ? values.runs : "3";
  const runs = parseInt(runsStr, 10);
  if (!Number.isFinite(runs) || runs <= 0) {
    throw new Error(`--runs must be a positive integer (got "${runsStr}")`);
  }

  const endpoint = typeof values.endpoint === "string" ? values.endpoint : DEFAULT_ENDPOINT;
  const apiKey =
    typeof values["api-key"] === "string" && values["api-key"] !== ""
      ? values["api-key"]
      : (process.env["GF_API_KEY"] ?? "dev-secret-change-me");

  return { evalId, runs, prompt, endpoint, apiKey };
}

/** Run the eval orchestration loop. Returns one RunResult per iteration. */
export async function runOrchestrator(
  opts: OrchestratorOpts,
  gfMod: GfModule = gf,
): Promise<RunResult[]> {
  const results: RunResult[] = [];

  for (let i = 0; i < opts.runs; i++) {
    const runId = `eval-${opts.evalId}-run-${i + 1}`;
    gfMod.init({ endpoint: opts.endpoint, apiKey: opts.apiKey, runId });

    // GF-733: evalScope per-run (per-task ALS isolation; Python parity).
    await gfMod.evalScope(opts.evalId, async () => {
      await gfMod.span("eval_run", { prompt: opts.prompt, run: i + 1 }, async () => {
        // Dummy agent hookup — real agent integration is L3.
        await new Promise((r) => setTimeout(r, 100));
        // eslint-disable-next-line no-console
        console.log(`  prompt: "${opts.prompt}"`);
      });
    });

    await gfMod.flush();
    results.push({ runId });
    // eslint-disable-next-line no-console
    console.log(`Run ${i + 1}/${opts.runs} → run_id: ${runId} ✅`);
  }

  return results;
}

/** Pure summary formatter — tests assert on the returned string instead of stdout capture. */
export function formatSummary(opts: OrchestratorOpts, results: RunResult[]): string {
  const line = "─".repeat(33);
  return [
    line,
    `Eval: ${opts.evalId}`,
    `Runs: ${results.length}`,
    `View: ${VIEWER_BASE}/${opts.evalId}`,
    line,
  ].join("\n");
}

async function main(): Promise<void> {
  const opts = parseCliArgs(process.argv.slice(2));
  const results = await runOrchestrator(opts);
  // eslint-disable-next-line no-console
  console.log(formatSummary(opts, results));
  await gf.shutdown();
}

// Only run main when invoked directly (not when imported by tests).
const invokedPath = process.argv[1];
if (invokedPath && import.meta.url === pathToFileURL(invokedPath).href) {
  main().catch((err) => {
    // eslint-disable-next-line no-console
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
