# ADR-004 — OTLP Compatibility Scope: Documented Subset + Collector Bridge

**Date:** 2026-06-11
**Status:** ACCEPTED (2026-06-11, Jiří Joneš)
**Issue:** GF-955 (Discovery — "Clarify OTel drop-in compatibility")
**Author:** Claude (CC CLI session 2026-06-11), for review by Jiří Joneš

---

## Context

The LP and README say "OTLP/HTTP JSON natively". A team with an app already
instrumented by a standard OTel SDK reads that as *drop-in*: repoint the exporter,
done. The actual ingest surface (`OtlpTranslator`, `otlp_translator.ex`) consumes
a deliberate subset:

| OTLP input | Behavior today |
|---|---|
| `stringValue` / `intValue` / `boolValue` / `doubleValue` attrs | translated to native types (GF-742/747) |
| `arrayValue` / `kvlistValue` attrs | **silently dropped** (`translate_attributes/1`, explicit L3-scope comment) |
| `kind`, `events`, `links`, OTLP `status`, `traceState` | **silently ignored** (`translate_span/1` picks 7 fields) |
| `resource.attributes["service.instance.id"]` | **required** — missing → `{:error, :missing_run_id}` → HTTP 400 |
| `startTimeUnixNano` invalid | graceful `nil` timestamps, span still accepted |

The hard incompatibility is the last-but-one row: `run_id` (the session unit —
the product's core differentiator) is read exclusively from
`service.instance.id`. Standard OTel SDK setups routinely set `service.name`
but **not** `service.instance.id`, so a true drop-in attempt most likely ends in
HTTP 400 on the first batch. The field drops are a softer problem (data loss the
customer only notices later); the 400 is a first-five-minutes failure.

## Decision

**A + C now, B-lite as a scoped follow-up. No semantic run_id fallback.**

### 1. (A) Document the subset — claim becomes "OTLP/HTTP JSON ingest" + compatibility matrix

- Add an **"OTLP compatibility"** section to `README.public.md`: the table above,
  verbatim — what is consumed, what is ignored, and that `service.instance.id`
  is the run_id carrier (with a copy-pasteable resource-attribute snippet).
- Soften the marketing wording from "natively" to "OTLP/HTTP JSON ingest — see
  the compatibility matrix". Precedent: GF-946/GF-960 established that any claim
  a reviewer can falsify in five minutes costs more than it earns. "Natively"
  invites exactly that test.

### 2. (C) Document the OTel Collector bridge as the supported full-OTel path

For teams with existing OTel instrumentation, the supported pattern is:

```
OTel SDK → OTel Collector (transform processor) → Span Chain /v1/traces
```

The Collector's `transform`/`resource` processor sets
`service.instance.id` (e.g. copied from an existing attribute or generated per
service instance) without touching application code. One documented YAML example
covers every OTel SDK in every language — far cheaper than chasing field-level
parity in our translator, and it is the standard escape hatch the OTel ecosystem
already expects.

### 3. (B-lite) Two small implementation items — separate Lane Ready issue(s)

- **`arrayValue`/`kvlistValue` → JSON-stringified fallback** in
  `translate_attributes/1`. Lossy-but-visible beats silently-absent in an audit
  product; values become inspectable strings in the payload. Small, pure,
  testable (the translator has no dependencies). Payload hashing is unaffected —
  attributes feed `PayloadSerializer.canonical_encode/1` the same way as any
  string.
- **Actionable 400 body** for `missing_run_id`: the error response should say
  *which* resource attribute is missing and show the snippet, instead of a bare
  reason. This converts the worst first-touch failure into a self-service fix.

### Rejected: run_id fallback from `service.name`

`service.name` is shared by every instance of a service. Falling back to it
would merge unrelated agent sessions into one run — silently corrupting the very
unit ("agent session as the unit of analysis") the product is built around, and
appending unrelated spans to one hash chain. A loud, well-explained 400 is
strictly better than a quiet wrong merge. Likewise rejected: auto-generating a
run_id per request (every batch would become its own orphan run).

### Deferred (unchanged L3 scope)

`kind`, `events`, `links`, OTLP `status` mapping. No customer signal yet that
these carry load-bearing data for the audit use case; `events`→child-span or
`status`→`attributes["status"]` mapping are plausible L3 follow-ups once real
OTel traffic shows up. Documented in the compatibility matrix as "ignored".

## Consequences

- README gains a normative compatibility matrix; LP/README wording drops the
  unqualified "natively".
- New Lane Ready follow-up issue(s): stringify fallback + actionable 400
  (both translator-local, no pipeline/schema impact).
- A `docs/` Collector example (YAML) becomes part of the OTLP section.
- `OtlpTranslator` stays a dumb adapter — no schema or hash-chain changes.

## Uncertainties (genuine, not resolved here)

- **How often real OTel setups already set `service.instance.id`** — assumption
  "routinely not" is based on OTel semconv marking it optional and on common SDK
  defaults, not on customer telemetry. If early adopters turn out to have it set
  (e.g. via k8s resource detectors), the 400 problem shrinks and the matrix alone
  may suffice.
- **Whether anyone needs `events`/`links` for agent auditing** — no data; that is
  why their mapping stays deferred rather than rejected.

---

*ADR-004 · Status: ACCEPTED 2026-06-11 (GF-955) · Supersedes nothing · Implementation tracked in Linear under GF-955's parent epic.*
