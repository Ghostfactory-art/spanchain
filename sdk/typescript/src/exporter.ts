import type {
  BufferedSpan,
  GfConfig,
  OtlpExportRequest,
  OtlpKeyValue,
  OtlpResourceSpans,
  OtlpSpan,
  SpanAttrs,
} from "./types.js";

const MAX_ATTEMPTS = 3;
const BACKOFF_MS = [100, 200] as const;

/** Map a JS attribute value to an OTLP KeyValue entry. GF-742 type dispatch:
 * string → stringValue, boolean → boolValue, integer → intValue, other number → doubleValue.
 * Backend currently ignores doubleValue (L2 acceptable; emitted for future L3 aggregations). */
export function toOtlpKeyValue(key: string, value: string | number | boolean): OtlpKeyValue {
  if (typeof value === "string") {
    return { key, value: { stringValue: value } };
  }
  if (typeof value === "boolean") {
    return { key, value: { boolValue: value } };
  }
  // number
  if (Number.isInteger(value)) {
    return { key, value: { intValue: value } };
  }
  return { key, value: { doubleValue: value } };
}

export function attrsToKeyValueList(attrs: SpanAttrs): OtlpKeyValue[] {
  return Object.entries(attrs).map(([k, v]) => toOtlpKeyValue(k, v));
}

function buildResourceAttributes(config: GfConfig, evalId: string | undefined): OtlpKeyValue[] {
  const attrs: OtlpKeyValue[] = [
    { key: "service.instance.id", value: { stringValue: config.runId ?? "" } },
  ];
  if (evalId) {
    attrs.push({ key: "gf.eval_id", value: { stringValue: evalId } });
  }
  return attrs;
}

// GF-733: group buffered spans by effective evalId (BufferedSpan.evalId ?? config.evalId).
// Per-task isolation in flush time: parallel evalScope calls land in distinct
// ResourceSpans, each with its own gf.eval_id resource attribute.
export function buildExportRequest(
  buffered: BufferedSpan[],
  config: GfConfig,
): OtlpExportRequest {
  const groups = new Map<string | undefined, OtlpSpan[]>();
  for (const b of buffered) {
    const key = b.evalId ?? config.evalId;
    const arr = groups.get(key) ?? [];
    arr.push(b.otlp);
    groups.set(key, arr);
  }

  const resourceSpans: OtlpResourceSpans[] = Array.from(groups.entries()).map(
    ([evalId, spans]) => ({
      resource: { attributes: buildResourceAttributes(config, evalId) },
      scopeSpans: [{ spans }],
    }),
  );

  return { resourceSpans };
}

function debug(...args: unknown[]): void {
  if (process.env["GF_DEBUG"]) {
    // eslint-disable-next-line no-console
    console.error("[gf-sdk]", ...args);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Export buffered spans to the OTLP /v1/traces endpoint. Silent-fail: never throws to caller.
 * GF-733: BufferedSpan carries per-span evalId for resource-attribute grouping. */
export async function exportSpans(
  buffered: BufferedSpan[],
  config: GfConfig,
): Promise<boolean> {
  if (buffered.length === 0) {
    return true;
  }

  const body = JSON.stringify(buildExportRequest(buffered, config));
  const url = `${config.endpoint.replace(/\/+$/, "")}/v1/traces`;
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${config.apiKey}`,
  };

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const response = await fetch(url, { method: "POST", headers, body });
      if (response.ok) {
        return true;
      }
      debug(`attempt ${attempt} failed status=${response.status}`);
    } catch (err) {
      debug(`attempt ${attempt} threw`, err);
    }

    if (attempt < MAX_ATTEMPTS) {
      const delay = BACKOFF_MS[attempt - 1] ?? BACKOFF_MS[BACKOFF_MS.length - 1] ?? 100;
      await sleep(delay);
    }
  }

  debug(`exhausted ${MAX_ATTEMPTS} attempts, ${buffered.length} spans dropped`);
  return false;
}
