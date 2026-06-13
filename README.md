<p align="center">
  <img src=".github/assets/banner.svg" alt="Span Chain — deterministic replay for AI agents" width="900">
</p>

<p align="center">
  <em>Every agent leaves a record.&nbsp; We keep it.</em>
</p>

<p align="center">
  <img src=".github/assets/badges.svg" alt="status · license · ingest · replay" width="620">
</p>

<p align="center">
  <em>Tamper-evident audit trail for production AI agents. Append-only.<br>
  Cryptographically verifiable. Deterministically replayable.</em>
</p>

---

Span Chain treats the **agent session** as the unit of analysis — not the individual LLM call.
The entire run, with its parent/child span hierarchy intact, is recorded to an
**immutable, hash-chain–verified ledger** as the source of truth.

Replay a recorded session and its spans are **re-ingested into a new, independently
verified chain** — identical structure, fresh `run_id`, no LLM re-execution. Replay
validates Span Chain's integrity, not your agent's behavior.
Silent failures — HTTP 200, wrong answer — become inspectable instead of irreproducible.

Every agent action produces a **cryptographic receipt** — a tamper-evident record
SHA-256 chained to the previous action. Append-only. Offline verification via
`verify_ledger` — no LLM calls or external services required.

---

## How Span Chain compares

| | LangSmith / Langfuse | Span Chain |
|---|---|---|
| **Purpose** | Developer debug, visualization | Production auditability, integrity |
| **Traces** | Mutable, vendor-controlled | Append-only, hash-chained |
| **Replay** | Re-runs LLM ($) | Cassette replay ($0) |
| **Evidence** | Logs | Cryptographic verification |
| **Hosting** | Vendor SaaS | Self-hosted, MIT |
| **Debug cost** | Every retry = LLM call | $0 from cassette replay |
| **Architecture** | Stateless Python API | Elixir/OTP per-run isolation |

**LangSmith** is built for development debugging and trace visualization.
**Span Chain** is built for production auditability and tamper-evident evidence.

**Langfuse** is built for tracing and analytics.
**Span Chain** is built for cryptographic verification and deterministic
replay without LLM calls.

**Elixir/OTP per-run isolation** — each agent run gets its own supervised process;
a crash in one run never affects another.

If you are targeting EU AI Act compliance, Span Chain's tamper-evident
ledger provides the tamper-evident audit trail that makes Article 12 traceability verifiable.

**Audit trail for compliance programs:** designed to support EU AI Act Article 12
traceability, SOC 2 audit-trail controls, and HIPAA audit-logging requirements.
Span Chain provides the evidence layer — your compliance program provides the rest.

> They show you what happened. We keep the proof.

---

## How it works

<p align="center">
  <img src=".github/assets/hash-chain.svg" alt="Hash-chain ledger" width="700">
</p>

Each entry in the ledger contains a SHA-256 hash of the previous entry.
Tampered records and dropped epochs are **detectable**, not assumed away.

---

## See it in action

<p align="center">
  <img src=".github/assets/spanchain-trail-evidence.png" alt="Span Chain Trail — hash-verified span tree with the agent's reasoning inline" width="860">
</p>

<p align="center">
  <sub>The <b>Trail</b> — a run's full span tree, every entry hash-chain verified, with the agent's own reasoning captured inline.</sub>
</p>

<p align="center">
  <img src=".github/assets/spanchain-structural-diff.png" alt="Span Chain Evals — structural span-tree diff between two runs" width="860">
</p>

<p align="center">
  <sub><b>Evals compare</b> — a structural span-tree diff pinpoints the exact span where two runs diverge.</sub>
</p>

---

## Properties

<table align="center">
  <tr>
    <td align="center" width="260">
      <img src=".github/assets/stamp-verified.svg" width="110"><br>
      <b>Verified</b><br>
      <sub>Every entry cryptographically linked to the last</sub>
    </td>
    <td align="center" width="260">
      <img src=".github/assets/stamp-deterministic.svg" width="125"><br>
      <b>Deterministic Replay</b><br>
      <sub>Same session → identical chain, always</sub>
    </td>
    <td align="center" width="260">
      <img src=".github/assets/stamp-tamper.svg" width="115"><br>
      <b>Tamper Detection</b><br>
      <sub>Dropped epochs and mutations surface automatically</sub>
    </td>
  </tr>
  <tr>
    <td colspan="3" align="center">
      <b>Non-repudiation</b><br>
      <sub>Cryptographic proof that an agent action occurred and was not modified</sub>
    </td>
  </tr>
</table>

---

## Architecture

<p align="center">
  <img src=".github/assets/architecture.svg" alt="Span Chain architecture" width="860">
</p>

```
SDK (OTLP / JSON)
  → Ingest  (normalize, span tree)
    → Hash-Chain Ledger  (source of truth · immutable · verifiable)
      ├── Deterministic Replay
      ├── Evals & Compare
      └── Audit Trail
```

---

## Quickstart

Requires Docker Compose v2 and a `.env` file:

```bash
git clone https://github.com/ghostfactory-art/spanchain.git
cd spanchain
cp .env.example .env
# Edit .env — set POSTGRES_PASSWORD, GF_API_KEY, and SECRET_KEY_BASE
docker compose up
```

UI at **http://localhost** · Ingest API at **http://localhost/ingest**

**Send a trace (OTLP/HTTP JSON):**

```bash
curl -X POST https://localhost/v1/traces --insecure \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SPANCHAIN_KEY" \
  -d @your-trace.json
```

> **TLS:** default Docker setup uses a local CA — add `--insecure` to skip, or trust once
> via `caddy trust`. See [Known Issues](#known-issues) for details.

Or use the plain JSON endpoint at `http://localhost/ingest` — no OTLP SDK required.

Works natively with **LangChain, CrewAI, LlamaIndex, AutoGen, and Pydantic AI**
via standard OpenTelemetry (OTLP) — no framework-specific SDK required.

---

## OTLP Compatibility

Span Chain ingestuje **OTLP/HTTP JSON** (`POST /v1/traces`) — subset standardu.
Full OTel drop-in compatibility není cílem L2; chybějící pole jsou ignorována
beze stopy (`lossy-but-visible` per ADR-004).

### Attribute value types

| OTLP type     | Span Chain chování              |
|---------------|---------------------------------|
| `stringValue` | uložen jako string ✅           |
| `intValue`    | uložen jako integer ✅          |
| `boolValue`   | uložen jako boolean ✅          |
| `doubleValue` | uložen jako float ✅            |
| `arrayValue`  | JSON-stringified string ⚠️     |
| `kvlistValue` | JSON-stringified string ⚠️     |

### Required resource attribute

`service.instance.id` **musí** být přítomno — mapuje se na `run_id`.
Chybějící → HTTP 400 `missing_run_id`.

```json
{
  "resourceSpans": [{
    "resource": {
      "attributes": [{
        "key": "service.instance.id",
        "value": { "stringValue": "my-agent-run-001" }
      }]
    },
    ...
  }]
}
```

### Co se ignoruje

- `events`, `links` — neuloženy
- scope attributes — neuloženy (pouze resource + span attributes)
- `traceState`, `droppedAttributesCount` — neuloženy

### HTTP response

Úspěšný ingest → HTTP **200** + `{"partialSuccess":{"rejectedSpans":0}}`.
(Ne 202 — to vrací jen `/ingest` endpoint.)

### OTel Collector bridge

Máš standardní OTel SDK bez možnosti nastavit `service.instance.id`?
Použij OTel Collector jako mezičlánek:

```yaml
# OTel Collector bridge → Span Chain
# Mapuje service.name → service.instance.id (run_id carrier pro Span Chain)
receivers:
  otlp:
    protocols:
      http:
        endpoint: "0.0.0.0:4318"

processors:
  transform/spanchain:
    trace_statements:
      - context: resource
        statements:
          - set(attributes["service.instance.id"], attributes["service.name"])

exporters:
  otlphttp/spanchain:
    endpoint: "https://your-spanchain-instance/v1/traces"
    headers:
      Authorization: "Bearer ${env:GF_API_KEY}"

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [transform/spanchain]
      exporters: [otlphttp/spanchain]
```

---

## SDKs

Both SDKs ship in this repo and speak OTLP/HTTP JSON (subset — see [OTLP Compatibility](#otlp-compatibility)).

**Python:**

```bash
pip install ./sdk/python
```

**TypeScript:**

```bash
npm install ./sdk/typescript
```

Usage examples in [`sdk/python/README.md`](sdk/python/README.md) and
[`sdk/typescript/README.md`](sdk/typescript/README.md).

---

## Status

v0.x · launched June 2026 · active development.

A **[GhostFactory](https://ghostfactory.art)** product — [spanchain.art](https://spanchain.art)

---

## What is public

By default, `/trail` and `/eval/:id` are accessible without authentication.
These views expose metadata: run IDs, span names, timing, and agent config diffs
(`gf.agent.*` attributes). **Span payloads remain token-gated** (`GF_API_KEY`).

For internet-facing or shared instances, set `TRAIL_AUTH_ENABLED=true` in `.env`.
This enables HTTP Basic Auth on Trail/Eval views (password = `GF_API_KEY`).

---

## Known Issues

**TLS certificate (localhost):** With the default `DOMAIN=localhost`, Caddy terminates HTTPS
using its own local CA, so on first run your browser shows an SSL warning and `curl` fails with
a certificate error. Trust the local CA once:

```bash
docker compose exec caddy caddy trust
```

Restart the browser afterwards (on Windows/Docker Desktop this is usually required; on WSL2 you can
confirm the cert landed in `/etc/ssl/certs/`). To skip trusting, bypass per-request instead —
`curl --insecure` or click through the browser's "advanced" warning. Not needed when `DOMAIN` is a
real domain (Caddy uses Let's Encrypt).

**Windows (WSL2):** Line endings in `entrypoint.sh` — if the container exits with
`exec format error`, run `dos2unix entrypoint.sh` before building.

**macOS (Apple Silicon):** Untested. Should work via Docker Desktop ARM emulation.

**Linux:** Untested. Standard `docker compose up` expected to work.

---

## License

MIT — see [LICENSE](LICENSE).
