/** Public config passed to gf.init(). */
export interface GfConfig {
  endpoint: string;
  apiKey: string;
  runId?: string;
  evalId?: string;
}

/** Public attribute map for gf.span() — string/number/boolean only (matches Elixir backend). */
export type SpanAttrs = Record<string, string | number | boolean>;

/** OTLP KeyValue value variants the GhostFactory backend extracts.
 * `doubleValue` is currently ignored by the backend `OtlpTranslator`
 * (L2 acceptable gap per GF-742) but emitted correctly so L3 aggregations
 * can be added without an SDK bump. */
export type OtlpValue =
  | { stringValue: string }
  | { intValue: number }
  | { boolValue: boolean }
  | { doubleValue: number };

export interface OtlpKeyValue {
  key: string;
  value: OtlpValue;
}

export interface OtlpSpan {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: string;
  startTimeUnixNano: string;
  endTimeUnixNano: string;
  attributes: OtlpKeyValue[];
}

export interface OtlpResource {
  attributes: OtlpKeyValue[];
}

export interface OtlpScopeSpans {
  spans: OtlpSpan[];
}

export interface OtlpResourceSpans {
  resource: OtlpResource;
  scopeSpans: OtlpScopeSpans[];
}

export interface OtlpExportRequest {
  resourceSpans: OtlpResourceSpans[];
}

/** Internal in-memory buffer entry (GF-733). `evalId` is NOT part of OTLP wire
 * format — exporter strips it and uses it for resource-attribute grouping
 * (per-task eval isolation via AsyncLocalStorage; spans captured under different
 * `evalScope` calls land in distinct ResourceSpans at export time). */
export interface BufferedSpan {
  otlp: OtlpSpan;
  evalId?: string;
}
