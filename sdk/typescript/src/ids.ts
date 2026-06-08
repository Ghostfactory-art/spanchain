import { randomBytes, randomUUID } from "node:crypto";

/** OTLP traceId — 16 random bytes hex-encoded (32 chars). */
export function newTraceId(): string {
  return randomBytes(16).toString("hex");
}

/** OTLP spanId — 8 random bytes hex-encoded (16 chars). */
export function newSpanId(): string {
  return randomBytes(8).toString("hex");
}

/** Default runId fallback (UUID v4) — runId is a free-form service.instance.id, UUID is fine. */
export function newRunId(): string {
  return randomUUID();
}
