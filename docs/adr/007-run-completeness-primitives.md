# ADR-007 — Run Completeness Primitives: In-Chain Close Marker + Declared Span Count

**Date:** 2026-06-11
**Status:** ACCEPTED (2026-06-11, Jiří Joneš; design for L3 — no implementation in this ADR)
**Issue:** GF-954 (Discovery — "Design completeness primitives — span count attestation for billing")
**Author:** Claude (CC CLI session 2026-06-11), for review by Jiří Joneš

---

## Context

Server-side `seq` is assigned by `SessionGenServer` — a span the SDK loses
**never reaches** the SGS, so it leaves no gap in the hash chain.
`verify_ledger/1` therefore proves *integrity of what was delivered*, not
*completeness of what happened* (GF-943's framing). GF-943 made client-side loss
visible (warnings + `gf.flush()`), but the server still cannot attest "this run
is complete / missing N spans". Billing per span on top of lossy ingest is a
dispute waiting for the first invoice; the same gap weakens the AI-Act
traceability story.

Options from the issue: **A)** client-declared span count at flush/shutdown,
**B)** SDK-side sequence numbers per span, **C)** explicit run-close event,
**D)** combination.

## Decision

**D — one mechanism, not two: an explicit close marker span that carries the
declared span count, flowing through the existing ingest path into the hash
chain itself.**

### Mechanism

1. **SDK** (`gf.shutdown()` / new `gf.close_run()`; TS analog): after a final
   `flush()`, send one ordinary span named **`gf.run.close`** with attributes:
   - `gf.run.declared_span_count` (int) — spans *created* by this SDK instance
     (including any that sat in the buffer or were FIFO-dropped — created is the
     honest denominator),
   - `gf.sdk.instance_id` (string) — random per-process id, future-proofing for
     multi-process runs.
2. **Server**: no new endpoint, no SGS change — the marker rides the normal
   SGS → Broadway → Ledger path and is **hash-chained like any other span**, so
   the attestation itself is tamper-evident (deleting or editing it breaks the
   chain). `Pipeline.handle_batch` projects it into `runs`:
   - `runs.declared_span_count :integer` (new, nullable),
   - `runs.closed_at :utc_datetime` (new, nullable; `status` stays untouched).
   Both via the **ON CONFLICT first-wins** pattern (billing-critical per
   CLAUDE.md — never `COALESCE update_all`); a second close marker with a
   *different* count is suspicious and logged, not applied.
3. **Read side**: completeness is *derived*, not stored —
   `received = count(ledger_entries where run_id) - markers`;
   `GET /api/runs/:id/verify` response gains
   `completeness: "complete" | "missing_spans" | "unattested"` + `missing_count`.
   A run without a marker is **`unattested`** (today's semantics, unchanged) —
   crash before close, foreign OTLP SDK, old SDK versions all land here honestly.

### Why this shape

- **C alone** flags open vs closed but cannot quantify loss; **A alone** needs a
  transport anyway — putting the count *in* the close marker makes one span do
  both jobs, with zero new API surface and full backward compatibility (servers
  ignore unknown attributes; old SDKs simply never close).
- **In-chain beats sidecar**: a count delivered out-of-band (header, separate
  endpoint) would itself be unauditable. Inside the ledger it inherits the
  product's own integrity guarantee — pleasingly self-similar for an audit
  product.
- **"SDK stays dumb" survives**: the SDK adds one counter and one final span;
  comparison, projection, verdicts all stay backend-side (ADR-001 principle).

### Rejected / deferred: B (SDK-side per-span sequence numbers)

Most precise (identifies *which* spans vanished, detects mid-stream loss before
close) but: per-span payload growth on every span ever sent, a process-global
counter interacts badly with multi-process agents sharing a `run_id` (the
counter would need instance scoping anyway), and it still cannot see tail loss
(missing trailing seqs only become visible at close — which the marker already
covers). Deferred as an opt-in "billing mode" extension if L3 billing disputes
demand span-level identification; the close-marker schema above doesn't preclude
it.

## Consequences

- Migration: two nullable columns on `runs` (additive, no backfill needed).
- SDK API: Python `gf.close_run()` (or fold into an async-context `gf.run()`
  wrapper later); TS `gf.shutdown()` extended. Both backward compatible.
- `verify_ledger/1` itself **unchanged** — completeness is a layer above
  integrity, and the two verdicts stay separate (a run can be `verified: true`
  and `missing_spans` simultaneously; that is precisely the honest message).
- README/LP language can graduate from "tamper-evident" to "tamper-evident +
  completeness-attested (when runs are closed)" once shipped.
- Follow-up implementation issues (L3): SDK counters + close API, Pipeline
  projection + migration, verify endpoint extension, UI badge (open /
  unattested / complete / missing N).

## Uncertainties (genuine, not resolved here)

- **Multi-process runs**: how often does one `run_id` span multiple SDK
  processes today? v1 semantics defined here are per-instance-sum (markers
  keyed by `gf.sdk.instance_id`), but "all instances closed" detection needs a
  declared instance count or a timeout heuristic — left open; v1 may simply
  document single-instance scope.
- **Billing unit**: if L3 billing lands per-run rather than per-span, the count
  attestation drops from "billing-critical" to "trust feature" — the design
  holds either way, but priority should be re-checked against the actual L3
  billing model.
- **Foreign OTLP SDKs** can in principle send the marker attributes themselves
  (documented convention), but nothing forces them to be truthful or present —
  completeness attestation is only as strong as the emitting SDK. `unattested`
  is the permanent floor for arbitrary OTel traffic.

---

*ADR-007 · Status: ACCEPTED 2026-06-11 (GF-954) · Integrity (`verify_ledger`) and completeness remain separate verdicts by design.*
