# ADR-006 — Optional Auth Gate for /trail: Env-Flagged Basic Auth, Default Off

**Date:** 2026-06-11
**Status:** ACCEPTED (2026-06-11, Jiří Joneš)
**Issue:** GF-950 (Discovery — "Add optional auth gate for /trail LiveView")
**Author:** Claude (CC CLI session 2026-06-11), for review by Jiří Joneš

---

## Context

`/trail`, `/trail/:run_id` and `/eval/:eval_id` run in the `:browser` pipeline
(`web/router.ex`) with **no auth** — only a per-IP rate limit (GF-851). In the
GF-769 production topology Caddy routes everything except ingest/health to port
4001, so on a default real-domain deployment these pages are internet-reachable.

"Public read-only by design" is documented (`development.md`). What was *not*
documented is the concrete data consequence. Verified against the LiveView
sources (`trail_live.ex`, `eval_live.ex:159-167`):

**Exposed without a token:** run_ids (often customer naming conventions),
span names (typically tool/function names — they sketch the agent's
architecture), span status + durations + counts, eval ids, eval compare
summaries, and **agent config diff values** — `val_a`/`val_b` of any
`gf.agent.*` attribute (model, temperature, `system_prompt_hash`, version, …).

**Not exposed:** span payloads (prompts/outputs). Those render only through the
Bearer-gated `/api` (React UI) and port-4000 endpoints. The LiveViews read
payload fields solely to derive status/duration.

So the leak is metadata-grade, not content-grade — but for the audiences this
product courts (security reviewers, compliance buyers), *"your agent topology
and model config are public by default"* is a finding, not a nuance.

## Decision

**A-lite + B: conditional HTTP Basic Auth behind `TRAIL_AUTH_ENABLED` (default
off), plus explicit README documentation of the exposure either way.**

### 1. Env-flagged gate (A-lite)

- `TRAIL_AUTH_ENABLED=true` → the `:browser` pipeline enforces **`Plug.BasicAuth`**
  (any username, password = `GF_API_KEY`). Default **off** = today's behavior.
- Why Basic Auth and not a login form or `?token=` query param:
  - browsers handle it natively → zero UI work, no new dependency;
  - a query-param token leaks into server logs, browser history and Referer
    headers — rejected outright;
  - a session login form is real scope (form, session lifecycle, logout) with no
    added security over Basic Auth on a single-secret, single-tenant system.
- Why password = `GF_API_KEY` and not a second secret: the deployment already
  has exactly one trust domain and one secret (ingest, `/api`, React Connect all
  use it). A separate `TRAIL_AUTH_TOKEN` would add .env churn without adding a
  boundary; it can be introduced later if multi-tenant (L3) splits trust domains.

**Implementation requirement (not optional):** the plug alone does not cover the
LiveView **WebSocket mount** — `/live` socket traffic does not re-run router
pipelines. The gate must also be enforced at mount via `live_session ... on_mount`
(check a session flag set by the plug after successful Basic Auth). Gating only
the HTTP request would leave a fragile side door.

### 2. Documentation (B) — happens regardless of the flag

`README.public.md` (Known Issues or a new "What is public" section) states
plainly: */trail and /eval are unauthenticated by default and expose run ids,
span names, timing, and agent config metadata (model, temperature, prompt
hashes). Payloads are token-gated. Suitable for single-user deployments; set
`TRAIL_AUTH_ENABLED=true` for shared or internet-facing instances.*
`.env.example` documents the flag next to `GF_API_KEY`.

### Why default off

The dominant deployment today is single-user localhost (dev, dogfood, demo) and
the public demo value of `/trail` is real — the LP literally links people to a
live trail. Flipping the default would break the five-minute quickstart and the
dogfood story. The flag + loud documentation covers the shared-instance case
without taxing the common one. Revisit the default when multi-tenant lands (L3)
— at that point auth stops being optional.

### Interaction with ADR-008 / GF-953 (UI stack decision)

If GF-953 ends with LiveView deprecated, this gate is still worth its ~20 lines
(it protects the surface until deletion and costs nothing after). If GF-953
keeps LiveView as the admin/debug surface, this gate *is* the admin lock. Either
outcome leaves this decision valid — there is no ordering conflict.

## Consequences

- New Lane Ready follow-up: flag + `Plug.BasicAuth` + `on_mount` session check +
  2 tests (401 without credentials when enabled; unchanged when disabled) +
  README/.env.example documentation.
- `development.md` "public read-only by design" paragraph gets the data-consequence
  sentence and a pointer to the flag.
- No schema, pipeline, or API changes; React UI unaffected (its data path is
  already Bearer-gated).

## Uncertainties (genuine, not resolved here)

- **Whether any current deployment actually shares an instance** — the gate's
  urgency is speculative until a second user exists; that is why B (the warning)
  ships unconditionally and A-lite is a flag rather than a new default.
- **Basic Auth UX on the LP-linked public demo** — if the public demo instance
  ever enables the flag, the LP "see a live trail" link starts prompting for
  credentials; the demo instance should simply keep the flag off, but that
  coupling deserves a note in the deploy runbook when implemented.

---

*ADR-006 · Status: ACCEPTED 2026-06-11 (GF-950) · Default unchanged (public); flag is opt-in hardening until L3 multi-tenant.*
